#include "DiskDiagnostics.h"
#include <array>
#include <chrono>
#include <cstring>
#include <random>
#include <stdexcept>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winioctl.h>
#include <nvme.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif
namespace bg {
Json diskHealth(const fs::path& folder) {
    const auto volume = inspect(folder);
    Json result{{"model", volume.label}, {"medium", volume.device.medium == StorageMedium::ssd ? "SSD" :
        volume.device.medium == StorageMedium::hdd ? "HDD" : "类型未知"}, {"health", "无法读取 S.M.A.R.T.，设备、硬盘盒或权限未提供访问"},
        {"recording", volume.device.medium == StorageMedium::ssd ? "SSD 不适用" : "无法确认 SMR / CMR，需按准确型号查询厂商规格"},
        {"date", encodeTime(now())}};
#ifdef _WIN32
    wchar_t name[MAX_PATH]{};
    if (!GetVolumeNameForVolumeMountPointW(volume.mount.c_str(), name, MAX_PATH)) return result;
    std::wstring device(name); if (!device.empty() && device.back() == L'\\') device.pop_back();
    auto handle = CreateFileW(device.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return result;
    struct Close { HANDLE h; ~Close() { CloseHandle(h); } } close{handle};
    STORAGE_PROPERTY_QUERY query{StorageDeviceProperty, PropertyStandardQuery, {}};
    alignas(STORAGE_DEVICE_DESCRIPTOR) std::array<unsigned char, 4096> buffer{};
    DWORD received{};
    if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query), buffer.data(), static_cast<DWORD>(buffer.size()), &received, nullptr) &&
        received >= sizeof(STORAGE_DEVICE_DESCRIPTOR)) {
        const auto* desc = reinterpret_cast<const STORAGE_DEVICE_DESCRIPTOR*>(buffer.data());
        if (desc->ProductIdOffset > 0 && desc->ProductIdOffset < received) {
            const auto* model = reinterpret_cast<const char*>(buffer.data() + desc->ProductIdOffset);
            const auto max = received - desc->ProductIdOffset;
            result["model"] = std::string(model, strnlen(model, max));
        }
    }
    STORAGE_PREDICT_FAILURE failure{};
    if (DeviceIoControl(handle, IOCTL_STORAGE_PREDICT_FAILURE, nullptr, 0, &failure, sizeof(failure), &received, nullptr) && received >= sizeof(failure))
        result["health"] = failure.PredictFailure ? "设备报告健康警告" : "设备未报告健康警告";
    constexpr size_t base = offsetof(STORAGE_PROPERTY_QUERY, AdditionalParameters);
    buffer.fill(0);
    auto* request = reinterpret_cast<STORAGE_PROPERTY_QUERY*>(buffer.data());
    request->PropertyId = StorageDeviceProtocolSpecificProperty;
    request->QueryType = PropertyStandardQuery;
    auto* protocol = reinterpret_cast<STORAGE_PROTOCOL_SPECIFIC_DATA*>(buffer.data() + base);
    protocol->ProtocolType = ProtocolTypeNvme;
    protocol->DataType = NVMeDataTypeLogPage;
    protocol->ProtocolDataRequestValue = NVME_LOG_PAGE_HEALTH_INFO;
    protocol->ProtocolDataOffset = sizeof(*protocol);
    protocol->ProtocolDataLength = sizeof(NVME_HEALTH_INFO_LOG);
    if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY, buffer.data(), static_cast<DWORD>(buffer.size()),
                        buffer.data(), static_cast<DWORD>(buffer.size()), &received, nullptr) && received >= sizeof(STORAGE_PROTOCOL_DATA_DESCRIPTOR)) {
        const auto* response = reinterpret_cast<const STORAGE_PROTOCOL_DATA_DESCRIPTOR*>(buffer.data());
        const auto& data = response->ProtocolSpecificData;
        const auto start = offsetof(STORAGE_PROTOCOL_DATA_DESCRIPTOR, ProtocolSpecificData) + static_cast<size_t>(data.ProtocolDataOffset);
        if (response->Version == sizeof(*response) && data.ProtocolDataOffset >= sizeof(data) &&
            data.ProtocolDataLength >= sizeof(NVME_HEALTH_INFO_LOG) && start <= received && sizeof(NVME_HEALTH_INFO_LOG) <= received - start) {
            const auto* health = reinterpret_cast<const NVME_HEALTH_INFO_LOG*>(buffer.data() + start);
            result["health"] = health->CriticalWarning.AsUchar ? "设备报告健康警告" : "设备未报告健康警告";
            result["percentageUsed"] = health->PercentageUsed;
            const auto temperature = health->Temperature[0] | (health->Temperature[1] << 8);
            if (temperature) result["temperature"] = temperature - 273;
        }
    }
    if (volume.device.medium == StorageMedium::hdd) {
        buffer.fill(0);
        request->PropertyId = StorageDeviceProtocolSpecificProperty;
        request->QueryType = PropertyStandardQuery;
        protocol->ProtocolType = ProtocolTypeAta;
        protocol->DataType = AtaDataTypeIdentify;
        protocol->ProtocolDataOffset = sizeof(*protocol);
        protocol->ProtocolDataLength = 512;
        if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY, buffer.data(), static_cast<DWORD>(buffer.size()),
                            buffer.data(), static_cast<DWORD>(buffer.size()), &received, nullptr) && received >= sizeof(STORAGE_PROTOCOL_DATA_DESCRIPTOR)) {
            const auto* response = reinterpret_cast<const STORAGE_PROTOCOL_DATA_DESCRIPTOR*>(buffer.data());
            const auto& data = response->ProtocolSpecificData;
            const auto start = offsetof(STORAGE_PROTOCOL_DATA_DESCRIPTOR, ProtocolSpecificData) + static_cast<size_t>(data.ProtocolDataOffset);
            if (data.ProtocolDataOffset >= sizeof(data) && data.ProtocolDataLength >= 512 && start <= received && 512 <= received - start) {
                const auto zoned = buffer[start + 69 * 2] & 3;
                if (zoned == 1 || zoned == 2) result["recording"] = "设备报告 SMR 分区能力";
            }
        }
    }
#endif
    return result;
}
Json diskSpeed(const fs::path& folder) {
    Tree tree(folder);
    constexpr size_t window = 1024 * 1024, size = 64 * window;
    if (inspect(folder).free < size * 3) throw std::runtime_error("测速至少需要 192 MiB 可用空间");
    const auto name = ".backup-genius-speed-" + uuid();
    using Clock = std::chrono::steady_clock;
    auto seconds = [](auto start) { return std::max(0.000001, std::chrono::duration<double>(Clock::now() - start).count()); };
    double writeTime{}, readTime{}, latency{};
    bool created = false;
    try {
#ifdef _WIN32
        auto path = tree.checked(name);
        auto h = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH, nullptr);
        if (h == INVALID_HANDLE_VALUE) throw std::runtime_error("无法创建测速文件");
        created = true;
        struct Handle { HANDLE h; ~Handle() { CloseHandle(h); } } handle{h};
        auto buffer = static_cast<unsigned char*>(VirtualAlloc(nullptr, window, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
        if (!buffer) throw std::bad_alloc();
        struct Memory { void* p; ~Memory() { VirtualFree(p, 0, MEM_RELEASE); } } memory{buffer};
        std::mt19937 random(std::random_device{}());
        for (size_t i = 0; i < window; ++i) buffer[i] = static_cast<unsigned char>(random());
        const auto expected = sha256(std::string_view(reinterpret_cast<char*>(buffer), window));
        auto transfer = [&](size_t offset, size_t length, bool write) {
            tree.check();
            LARGE_INTEGER position{}; position.QuadPart = offset;
            DWORD count{};
            if (!SetFilePointerEx(h, position, nullptr, FILE_BEGIN) ||
                !(write ? WriteFile(h, buffer, static_cast<DWORD>(length), &count, nullptr) : ReadFile(h, buffer, static_cast<DWORD>(length), &count, nullptr)) || count != length)
                throw std::runtime_error("测速读写失败，请保持硬盘连接");
        };
        auto begin = Clock::now();
        for (size_t offset = 0; offset < size; offset += window) transfer(offset, window, true);
        if (!FlushFileBuffers(h)) throw std::runtime_error("测速文件落盘失败");
        writeTime = seconds(begin);
        begin = Clock::now();
        for (size_t offset = 0; offset < size; offset += window) {
            transfer(offset, window, false);
            if (sha256(std::string_view(reinterpret_cast<char*>(buffer), window)) != expected) throw std::runtime_error("测速读回校验失败");
        }
        readTime = seconds(begin);
        begin = Clock::now();
        for (size_t i = 0; i < 64; ++i) transfer(((i * 7919) % (size / 4096)) * 4096, 4096, false);
        latency = seconds(begin) * 1000 / 64;
#else
        auto file = tree.file(name, File::Mode::create);
        created = true;
        const auto descriptor = ::open(tree.checked(name).c_str(), O_RDONLY);
        if (descriptor >= 0) { fcntl(descriptor, F_NOCACHE, 1); ::close(descriptor); }
        Bytes buffer(window, ' ');
        std::mt19937 random(std::random_device{}());
        for (auto& b : buffer) b = static_cast<char>(random());
        auto begin = Clock::now();
        for (size_t offset = 0; offset < size; offset += window) file.write(offset, buffer);
        file.flush(); writeTime = seconds(begin);
        begin = Clock::now();
        for (size_t offset = 0; offset < size; offset += window) if (file.read(offset, window) != buffer) throw std::runtime_error("测速读回校验失败");
        readTime = seconds(begin);
        begin = Clock::now();
        for (size_t i = 0; i < 64; ++i) file.read(((i * 7919) % (size / 4096)) * 4096, 4096);
        latency = seconds(begin) * 1000 / 64;
#endif
    } catch (...) { if (created) { try { tree.remove(name); } catch (...) {} } throw; }
    tree.remove(name);
    return {{"read", size / readTime}, {"write", size / writeTime}, {"latency", latency}, {"bytes", size}, {"date", encodeTime(now())}};
}
}
