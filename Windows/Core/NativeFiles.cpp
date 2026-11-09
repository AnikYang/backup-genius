#include "NativeFiles.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <system_error>
#include <utility>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <winioctl.h>
#else
#include <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace bg {
namespace {
[[noreturn]] void fail(const char* operation) {
#ifdef _WIN32
    throw std::system_error(static_cast<int>(GetLastError()), std::system_category(), operation);
#else
    throw std::system_error(errno, std::generic_category(), operation);
#endif
}
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

#ifdef _WIN32
HANDLE handle(intptr_t value) { return reinterpret_cast<HANDLE>(value); }
constexpr int64_t windowsEpoch = 116444736000000000LL;
Time fromTicks(int64_t value) {
    value -= windowsEpoch;
    auto seconds = value / 10'000'000;
    auto remainder = value % 10'000'000;
    if (remainder < 0) { --seconds; remainder += 10'000'000; }
    return {seconds, static_cast<int32_t>(remainder * 100)};
}
FILETIME toTime(Time value) {
    require(value.seconds >= -11644473600LL && value.seconds < 900000000000LL, "时间超出 Windows 范围");
    ULARGE_INTEGER time{};
    time.QuadPart = static_cast<uint64_t>(value.seconds * 10'000'000 + value.nanoseconds / 100 + windowsEpoch);
    return {time.LowPart, time.HighPart};
}
fs::path longPath(const fs::path& p) {
    auto native = p;
    auto text = native.make_preferred().wstring();
    if (text.starts_with(L"\\\\?\\")) return native;
    if (text.starts_with(L"\\\\")) return fs::path(L"\\\\?\\UNC\\" + text.substr(2));
    return fs::path(L"\\\\?\\" + text);
}
Stamp handleStamp(HANDLE h) {
    BY_HANDLE_FILE_INFORMATION legacy{};
    if (!GetFileInformationByHandle(h, &legacy)) fail("GetFileInformationByHandle");
    FILE_BASIC_INFO basic{};
    if (!GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic))) fail("FileBasicInfo");
    const auto flags = legacy.dwFileAttributes;
    Kind kind = flags & FILE_ATTRIBUTE_DIRECTORY ? Kind::directory : Kind::regular;
    if (flags & FILE_ATTRIBUTE_REPARSE_POINT) {
        FILE_ATTRIBUTE_TAG_INFO tag{};
        kind = GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof(tag)) &&
            tag.ReparseTag == IO_REPARSE_TAG_SYMLINK ? Kind::link : Kind::unsupported;
    }
    FILE_ID_INFO id{};
    std::string identity;
    if (GetFileInformationByHandleEx(h, FileIdInfo, &id, sizeof(id))) {
        identity = base64(std::string_view(reinterpret_cast<const char*>(&id.FileId), sizeof(id.FileId)));
    } else {
        identity = std::to_string(legacy.nFileIndexHigh) + ":" + std::to_string(legacy.nFileIndexLow);
    }
    identity = std::to_string(legacy.dwVolumeSerialNumber) + ":" + identity + ":" +
        std::to_string(basic.CreationTime.QuadPart);
    return {kind, kind == Kind::regular ? static_cast<int64_t>((uint64_t{legacy.nFileSizeHigh} << 32) |
        legacy.nFileSizeLow) : 0, fromTicks(basic.LastWriteTime.QuadPart),
        fromTicks(basic.CreationTime.QuadPart), fromTicks(basic.ChangeTime.QuadPart), flags, std::move(identity)};
}
std::optional<Stamp> probe(const fs::path& p) {
    HANDLE h = CreateFileW(p.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        auto code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND || code == ERROR_DIRECTORY) return {};
        fail("CreateFileW attributes");
    }
    try {
        auto s = handleStamp(h);
        CloseHandle(h);
        return s;
    } catch (...) { CloseHandle(h); throw; }
}

// Keep the resolved directory chain from being replaced by a junction while a
// Win32 operation uses its path. The final file is opened without reparse traversal.
class PinDirectories {
    struct Close { void operator()(void* h) const { CloseHandle(h); } };
    std::vector<std::unique_ptr<void, Close>> pins_;

    void pin(const fs::path& p, const Stamp* root = nullptr) {
        auto h = CreateFileW(p.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (h == INVALID_HANDLE_VALUE) fail("打开文件夹保护句柄");
        std::unique_ptr<void, Close> file(h);
        auto stamp = handleStamp(h);
        require(stamp.kind == Kind::directory && (!root || stamp.identity == root->identity), "文件夹已替换或指向链接");
        pins_.push_back(std::move(file));
    }
public:
    PinDirectories(const fs::path& root, const Stamp& expected, std::string_view relative) {
        require(relative.empty() || representable(relative), "路径无法安全表示");
        auto p = longPath(root);
        pin(p, &expected);
        while (true) {
            auto end = relative.find('/');
            if (end == relative.npos) break;
            p /= path(relative.substr(0, end));
            pin(p);
            relative.remove_prefix(end + 1);
        }
    }
};
#else
fs::path longPath(const fs::path& p) { return p; }
Stamp makeStamp(const struct stat& st) {
    auto time = [](timespec value) { return Time{value.tv_sec, static_cast<int32_t>(value.tv_nsec)}; };
    Kind kind = Kind::unsupported;
    if (S_ISREG(st.st_mode)) kind = Kind::regular;
    if (S_ISDIR(st.st_mode)) kind = Kind::directory;
    if (S_ISLNK(st.st_mode)) kind = Kind::link;
    return {kind, kind == Kind::regular ? st.st_size : 0, time(st.st_mtimespec), time(st.st_birthtimespec),
        time(st.st_ctimespec), static_cast<uint32_t>(st.st_mode & 0777), std::to_string(st.st_dev) + ":" +
        std::to_string(st.st_ino) + ":" + std::to_string(st.st_birthtimespec.tv_sec)};
}
std::optional<Stamp> probe(const fs::path& p) {
    struct stat st{};
    if (lstat(p.c_str(), &st) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return {};
        fail("lstat");
    }
    return makeStamp(st);
}
struct PinDirectories {
    PinDirectories(const fs::path&, const Stamp&, std::string_view) {}
};
#endif

constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
}

fs::path path(std::string_view text) {
    return fs::path(std::u8string(reinterpret_cast<const char8_t*>(text.data()), text.size()));
}
std::string utf8(const fs::path& value) {
    auto text = value.generic_u8string();
    return {reinterpret_cast<const char*>(text.data()), text.size()};
}
std::string folded(std::string_view value) {
#ifdef _WIN32
    auto text = path(value).wstring();
    if (text.empty()) return {};
    int n = NormalizeString(NormalizationC, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (n > 0) {
        std::wstring normalized(n, L'\0');
        n = NormalizeString(NormalizationC, text.data(), static_cast<int>(text.size()), normalized.data(), n);
        if (n > 0) { normalized.resize(n); text = std::move(normalized); }
    }
    n = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, text.data(), static_cast<int>(text.size()),
                      nullptr, 0, nullptr, nullptr, 0);
    if (n > 0) {
        std::wstring lower(n, L'\0');
        if (LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, text.data(), static_cast<int>(text.size()),
                          lower.data(), n, nullptr, nullptr, 0)) text = std::move(lower);
    }
    return utf8(fs::path(text));
#else
    std::string result(value);
    for (auto& c : result) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return result;
#endif
}
std::string parent(std::string_view value) {
    auto split = value.rfind('/');
    return split == value.npos ? "" : std::string(value.substr(0, split));
}
std::string name(std::string_view value) { return std::string(value.substr(value.rfind('/') + 1)); }
std::string join(std::string_view base, std::string_view child) {
    return base.empty() ? std::string(child) : std::string(base) + "/" + std::string(child);
}
bool inside(std::string_view value, std::string_view base) {
    return base.empty() || value == base || (value.starts_with(base) && value.size() > base.size() && value[base.size()] == '/');
}
bool validPath(std::string_view value, bool user) {
    if (value.empty() || value.size() > 131072 || value.front() == '/' || value.back() == '/' ||
        value.find('\0') != value.npos) return false;
    bool first = true;
    while (!value.empty()) {
        auto split = value.find('/');
        auto part = value.substr(0, split);
        if (part.empty() || part == "." || part == ".." || (user && first && folded(part) == control)) return false;
        if (split == value.npos) break;
        first = false;
        value.remove_prefix(split + 1);
    }
    return true;
}
bool representable(std::string_view value) {
    if (!validPath(value, false)) return false;
    while (!value.empty()) {
        auto split = value.find('/');
        auto part = value.substr(0, split);
        if (part.back() == '.' || part.back() == ' ' || part.find_first_of("<>:\"\\|?*") != part.npos ||
            std::any_of(part.begin(), part.end(), [](unsigned char c) { return c < 32 || c == 127; })) return false;
#ifdef _WIN32
        if (path(part).wstring().size() > 255) return false;
#endif
        auto base = folded(part.substr(0, part.find('.')));
        while (!base.empty() && base.back() == ' ') base.pop_back();
        if (base == "con" || base == "prn" || base == "aux" || base == "nul" || base == "conin$" || base == "conout$") return false;
        if (base.starts_with("com") || base.starts_with("lpt")) {
            auto suffix = base.substr(3);
            if ((suffix.size() == 1 && suffix.front() >= '1' && suffix.front() <= '9') ||
                suffix == "¹" || suffix == "²" || suffix == "³") return false;
        }
        if (split == value.npos) break;
        value.remove_prefix(split + 1);
    }
    return true;
}

std::string uuid() {
    std::array<unsigned char, 16> bytes{};
#ifdef _WIN32
    require(BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0,
            "无法生成备份标识");
#else
    arc4random_buf(bytes.data(), bytes.size());
#endif
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    std::string result;
    constexpr char hex[] = "0123456789ABCDEF";
    for (size_t i = 0; i < bytes.size(); ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) result += '-';
        result += hex[bytes[i] >> 4];
        result += hex[bytes[i] & 15];
    }
    return result;
}
Time now() {
    auto duration = std::chrono::system_clock::now().time_since_epoch();
    auto seconds = std::chrono::floor<std::chrono::seconds>(duration);
    return {seconds.count(), static_cast<int32_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(duration - seconds).count())};
}
Bytes sha256(std::string_view data) {
    Bytes out(32, '\0');
#ifdef _WIN32
    require(data.size() <= std::numeric_limits<ULONG>::max() &&
        BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
                   reinterpret_cast<PUCHAR>(const_cast<char*>(data.data())), static_cast<ULONG>(data.size()),
                   reinterpret_cast<PUCHAR>(out.data()), 32) >= 0, "SHA-256 校验失败");
#else
    CC_SHA256(data.data(), static_cast<CC_LONG>(data.size()), reinterpret_cast<unsigned char*>(out.data()));
#endif
    return out;
}
Bytes base64(std::string_view input) {
    Bytes out;
    out.reserve((input.size() + 2) / 3 * 4);
    for (size_t i = 0; i < input.size(); i += 3) {
        const auto n = input.size() - i;
        const auto a = static_cast<unsigned char>(input[i]);
        const auto b = n > 1 ? static_cast<unsigned char>(input[i + 1]) : 0;
        const auto c = n > 2 ? static_cast<unsigned char>(input[i + 2]) : 0;
        out += alphabet[a >> 2];
        out += alphabet[((a & 3) << 4) | (b >> 4)];
        out += n > 1 ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
        out += n > 2 ? alphabet[c & 63] : '=';
    }
    return out;
}
Bytes unbase64(std::string_view input) {
    require(input.size() % 4 == 0, "无效的 Base64 字段");
    static const auto lookup = [] {
        std::array<int, 256> values{};
        values.fill(-1);
        for (int i = 0; i < 64; ++i) values[static_cast<unsigned char>(alphabet[i])] = i;
        return values;
    }();
    Bytes out;
    out.reserve(input.size() / 4 * 3);
    for (size_t i = 0; i < input.size(); i += 4) {
        const auto a = lookup[static_cast<unsigned char>(input[i])];
        const auto b = lookup[static_cast<unsigned char>(input[i + 1])];
        const auto c = lookup[static_cast<unsigned char>(input[i + 2])];
        const auto d = lookup[static_cast<unsigned char>(input[i + 3])];
        require(a >= 0 && b >= 0 && (c >= 0 || (input[i + 2] == '=' && input[i + 3] == '=' && (b & 15) == 0)) &&
            (d >= 0 || (input[i + 3] == '=' && i + 4 == input.size() && (c < 0 || (c & 3) == 0))),
            "无效的 Base64 字段");
        out += static_cast<char>((a << 2) | (b >> 4));
        if (c >= 0) out += static_cast<char>((b << 4) | (c >> 2));
        if (d >= 0) out += static_cast<char>((c << 6) | d);
    }
    return out;
}

File::File(const fs::path& p, Mode mode) {
#ifdef _WIN32
    const auto access = mode == Mode::read ? GENERIC_READ : (GENERIC_READ | GENERIC_WRITE);
    const auto share = FILE_SHARE_READ | FILE_SHARE_DELETE | (mode == Mode::read ? FILE_SHARE_WRITE : 0);
    const auto disposition = mode == Mode::create ? CREATE_NEW : OPEN_EXISTING;
    auto h = CreateFileW(p.c_str(), access, share, nullptr, disposition, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) throw std::system_error(GetLastError(), std::system_category(), "CreateFileW " + utf8(p));
    handle_ = reinterpret_cast<intptr_t>(h);
#else
    auto flags = mode == Mode::read ? O_RDONLY : O_RDWR;
    if (mode == Mode::create) flags |= O_CREAT | O_EXCL;
    handle_ = ::open(p.c_str(), flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (handle_ < 0) throw std::system_error(errno, std::generic_category(), "open " + utf8(p));
#endif
    try { require(stamp().kind == Kind::regular, "需要普通文件"); }
    catch (...) { File cleanup(std::move(*this)); throw; }
}
File::File(File&& other) noexcept : handle_(std::exchange(other.handle_, -1)) {}
File& File::operator=(File&& other) noexcept {
    File previous(std::move(*this));
    handle_ = std::exchange(other.handle_, -1);
    return *this;
}
File::~File() {
    if (handle_ == -1) return;
#ifdef _WIN32
    CloseHandle(handle(handle_));
#else
    close(static_cast<int>(handle_));
#endif
}
Stamp File::stamp() const {
#ifdef _WIN32
    return handleStamp(handle(handle_));
#else
    struct stat st{};
    if (fstat(static_cast<int>(handle_), &st) != 0) fail("fstat");
    return makeStamp(st);
#endif
}
Bytes File::read(int64_t offset, size_t count) const {
    require(offset >= 0 && count <= 64 * 1024 * 1024, "读取范围无效");
    Bytes out(count, '\0');
    size_t done = 0;
#ifdef _WIN32
    LARGE_INTEGER at{};
    at.QuadPart = offset;
    if (!SetFilePointerEx(handle(handle_), at, nullptr, FILE_BEGIN)) fail("SetFilePointerEx");
    while (done < count) {
        DWORD bytes{};
        if (!ReadFile(handle(handle_), out.data() + done, static_cast<DWORD>(count - done), &bytes, nullptr)) fail("ReadFile");
        require(bytes != 0, "文件长度意外变化");
        done += bytes;
    }
#else
    while (done < count) {
        auto bytes = pread(static_cast<int>(handle_), out.data() + done, count - done, offset + static_cast<int64_t>(done));
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes < 0) fail("pread");
        require(bytes != 0, "文件长度意外变化");
        done += static_cast<size_t>(bytes);
    }
#endif
    return out;
}
void File::write(int64_t offset, std::string_view data) {
    require(offset >= 0 && data.size() <= 64 * 1024 * 1024, "写入范围无效");
#ifdef _WIN32
    LARGE_INTEGER at{};
    at.QuadPart = offset;
    if (!SetFilePointerEx(handle(handle_), at, nullptr, FILE_BEGIN)) fail("SetFilePointerEx");
    while (!data.empty()) {
        DWORD bytes{};
        if (!WriteFile(handle(handle_), data.data(), static_cast<DWORD>(data.size()), &bytes, nullptr)) fail("WriteFile");
        require(bytes != 0, "写入未完成");
        data.remove_prefix(bytes);
    }
#else
    while (!data.empty()) {
        auto bytes = pwrite(static_cast<int>(handle_), data.data(), data.size(), offset);
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes < 0) fail("pwrite");
        require(bytes != 0, "写入未完成");
        data.remove_prefix(static_cast<size_t>(bytes));
        offset += bytes;
    }
#endif
}
void File::resize(int64_t size) {
    require(size >= 0, "文件大小无效");
#ifdef _WIN32
    LARGE_INTEGER at{};
    at.QuadPart = size;
    if (!SetFilePointerEx(handle(handle_), at, nullptr, FILE_BEGIN) || !SetEndOfFile(handle(handle_))) fail("SetEndOfFile");
#else
    if (ftruncate(static_cast<int>(handle_), size)) fail("ftruncate");
#endif
}
void File::flush() {
#ifdef _WIN32
    if (!FlushFileBuffers(handle(handle_))) fail("FlushFileBuffers");
#else
    if (fcntl(static_cast<int>(handle_), F_FULLFSYNC) != 0 && fsync(static_cast<int>(handle_)) != 0) fail("fsync");
#endif
}
void File::times(Time modified, Time created) {
#ifdef _WIN32
    auto m = toTime(modified), c = toTime(created);
    if (!SetFileTime(handle(handle_), &c, nullptr, &m)) fail("SetFileTime");
#else
    (void)created;
    const timespec values[] = {{0, UTIME_OMIT}, {modified.seconds, modified.nanoseconds}};
    if (futimens(static_cast<int>(handle_), values)) fail("futimens");
#endif
}

Tree::Tree(fs::path root) : root_(fs::absolute(root).lexically_normal()) {
    auto found = probe(longPath(root_));
    require(found && found->kind == Kind::directory, "需要可访问的普通文件夹");
    identity_ = *found;
    // Reject an alias anywhere above the selected root.
    for (auto p = root_.parent_path(); !p.empty() && p != root_.root_path(); p = p.parent_path()) {
        auto item = probe(longPath(p));
        require(item && item->kind == Kind::directory, "文件夹位于链接或重解析点内");
    }
}
void Tree::check() const {
    auto actual = probe(longPath(root_));
    require(actual && actual->kind == Kind::directory && actual->identity == identity_.identity, "文件夹已移动、替换或断开");
}
fs::path Tree::checked(std::string_view relative) const {
    if (relative.empty()) return longPath(root_);
    require(representable(relative), "路径无法安全表示");
    auto current = longPath(root_);
    while (true) {
        auto end = relative.find('/');
        current /= path(relative.substr(0, end));
        if (end == relative.npos) return current;
        auto stamp = probe(current);
        if (stamp && stamp->kind != Kind::directory) throw std::runtime_error("拒绝进入链接或非文件夹");
        relative.remove_prefix(end + 1);
    }
}
std::optional<Stamp> Tree::entry(std::string_view relative) const { return probe(checked(relative)); }
File Tree::file(std::string_view relative, File::Mode mode) const {
    require(!relative.empty(), "根目录不可当作文件打开");
    const PinDirectories pin(root_, identity_, relative);
    return File(checked(relative), mode);
}
std::vector<std::string> Tree::children(std::string_view relative) const {
    auto p = checked(relative);
    auto found = probe(p);
    require(found && found->kind == Kind::directory, "需要普通文件夹");
    std::vector<std::string> results;
    for (const auto& entry : fs::directory_iterator(p)) results.push_back(utf8(entry.path().filename()));
    return results;
}
void Tree::walk(std::string_view relative, const std::function<void(const std::string&, const Stamp&)>& visit,
                bool skipControl) const {
    auto scan = [&](auto&& recurse, const std::string& prefix) -> void {
        for (const auto& child : children(prefix)) {
            if (skipControl && prefix.empty() && folded(child) == control) continue;
            auto rel = join(prefix, child);
            if (!representable(rel)) { visit(rel, Stamp{Kind::unsupported}); continue; }
            auto s = entry(rel);
            if (!s) continue;
            visit(rel, *s);
            if (s->kind == Kind::directory) recurse(recurse, rel);
        }
    };
    if (relative.empty()) return scan(scan, "");
    auto s = entry(relative);
    if (!s) return;
    visit(std::string(relative), *s);
    if (s->kind == Kind::directory) scan(scan, std::string(relative));
}
void Tree::mkdir(std::string_view relative) const {
    if (relative.empty()) return;
    const PinDirectories pin(root_, identity_, relative);
    auto p = checked(relative);
    auto s = probe(p);
    if (s) { require(s->kind == Kind::directory, "文件夹位置已被占用"); return; }
    fs::create_directory(p);
}
void Tree::parents(std::string_view relative) const {
    std::vector<std::string> parts;
    for (auto p = parent(relative); !p.empty(); p = parent(p)) parts.push_back(p);
    for (auto it = parts.rbegin(); it != parts.rend(); ++it) mkdir(*it);
}
void Tree::rename(std::string_view from, std::string_view to, bool replace) const {
    require(!from.empty() && !to.empty(), "根目录不可移动");
    const PinDirectories source(root_, identity_, from), destination(root_, identity_, to);
    const auto a = checked(from), b = checked(to);
#ifdef _WIN32
    if (!MoveFileExW(a.c_str(), b.c_str(), MOVEFILE_WRITE_THROUGH | (replace ? MOVEFILE_REPLACE_EXISTING : 0))) fail("MoveFileExW");
#else
    if (replace) fs::rename(a, b);
    else if (renamex_np(a.c_str(), b.c_str(), RENAME_EXCL) != 0) {
        if (errno != ENOTSUP || probe(b)) fail("renamex_np");
        fs::rename(a, b);
    }
#endif
}
void Tree::remove(std::string_view relative, bool keepNonEmpty) const {
    require(!relative.empty(), "根目录不可移除");
    if (!entry(relative)) return;
    const PinDirectories pin(root_, identity_, relative);
    std::error_code error;
    fs::remove(checked(relative), error);
    if (error && !(keepNonEmpty && error == std::errc::directory_not_empty)) throw std::system_error(error, "remove");
}
void Tree::removeOwned(std::string_view relative) const {
    auto actual = entry(relative);
    if (!actual) return;
    if (actual->kind == Kind::directory) for (const auto& child : children(relative)) removeOwned(join(relative, child));
    remove(relative);
}
void Tree::createLink(std::string_view relative, std::string_view target, bool directory) const {
    require(!target.empty() && target.find('\0') == target.npos, "链接记录无效");
    const PinDirectories pin(root_, identity_, relative);
    auto at = checked(relative);
    auto linkTarget = path(target).make_preferred();
#ifdef _WIN32
    const auto flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE | (directory ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0);
    if (!CreateSymbolicLinkW(at.c_str(), linkTarget.c_str(), flags))
        throw std::system_error(GetLastError(), std::system_category(), "无法还原符号链接");
#else
    (void)directory;
    fs::create_symlink(linkTarget, at);
#endif
}
Bytes Tree::readDocument(std::string_view relative) const {
    auto input = file(relative);
    auto size = input.stamp().size;
    require(size >= 0 && size <= 64 * 1024 * 1024, "记录大小异常");
    return input.read(0, static_cast<size_t>(size));
}
void Tree::writeDocument(std::string_view relative, std::string_view data, bool replace) const {
    require(data.size() <= 64 * 1024 * 1024, "备份记录超过大小限制");
    const auto temporary = join(parent(relative), ".write-" + uuid());
    auto output = file(temporary, File::Mode::create);
    try {
        output.write(0, data);
        output.flush();
        rename(temporary, relative, replace);
        flushDirectory(parent(relative));
    } catch (...) {
        try { remove(temporary); } catch (...) {}
        throw;
    }
}
void Tree::metadata(std::string_view relative, Time modified, Time created, uint32_t attributes, bool readOnly) const {
    const PinDirectories pin(root_, identity_, relative);
    auto p = checked(relative);
#ifdef _WIN32
    HANDLE h = CreateFileW(p.c_str(), FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) fail("CreateFileW metadata");
    const auto m = toTime(modified), c = toTime(created);
    auto success = SetFileTime(h, &c, nullptr, &m);
    auto error = GetLastError();
    CloseHandle(h);
    if (!success) { SetLastError(error); fail("SetFileTime"); }
    auto portable = attributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_ARCHIVE |
                                  (readOnly ? FILE_ATTRIBUTE_READONLY : 0));
    if (!SetFileAttributesW(p.c_str(), portable ? portable : FILE_ATTRIBUTE_NORMAL)) fail("SetFileAttributesW");
#else
    (void)created;
    (void)attributes;
    (void)readOnly;
    const timespec values[] = {{0, UTIME_OMIT}, {modified.seconds, modified.nanoseconds}};
    if (utimensat(AT_FDCWD, p.c_str(), values, AT_SYMLINK_NOFOLLOW)) fail("utimensat");
#endif
}
void Tree::flushDirectory(std::string_view relative) const {
#ifdef _WIN32
    // Same-volume journal publication uses MOVEFILE_WRITE_THROUGH.
    (void)relative;
#else
    int fd = open(checked(relative).c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) fail("open directory");
    auto result = fsync(fd);
    auto error = errno;
    close(fd);
    if (result != 0 && error != EINVAL && error != ENOTSUP) { errno = error; fail("fsync directory"); }
#endif
}
Bytes hashFile(const File& input, int64_t size, int64_t* bytes) {
    Bytes hashes;
    for (int64_t offset = 0; offset < size;) {
        const auto data = input.read(offset, static_cast<size_t>(std::min(blockSize, size - offset)));
        hashes += sha256(data);
        if (bytes) *bytes += data.size();
        offset += static_cast<int64_t>(data.size());
    }
    return hashes;
}
void copyChecked(const File& input, File& output, int64_t size, std::string_view hashes) {
    for (int64_t offset = 0; offset < size;) {
        auto bytes = input.read(offset, static_cast<size_t>(std::min(blockSize, size - offset)));
        require(sha256(bytes) == hashes.substr(static_cast<size_t>(offset / blockSize * 32), 32), "文件内容校验失败");
        output.write(offset, bytes);
        offset += static_cast<int64_t>(bytes.size());
    }
    output.flush();
}

Volume inspect(const fs::path& p) {
#ifdef _WIN32
    wchar_t mount[32768]{}, volumeName[MAX_PATH]{}, format[32]{}, label[MAX_PATH]{};
    DWORD serial{};
    if (!GetVolumePathNameW(p.c_str(), mount, static_cast<DWORD>(std::size(mount))) ||
        !GetVolumeNameForVolumeMountPointW(mount, volumeName, MAX_PATH) ||
        !GetVolumeInformationW(mount, label, MAX_PATH, &serial, nullptr, nullptr, format, 32)) fail("GetVolumeInformationW");
    ULARGE_INTEGER free{}, total{};
    if (!GetDiskFreeSpaceExW(mount, &free, &total, nullptr)) fail("GetDiskFreeSpaceExW");
    bool external = GetDriveTypeW(mount) == DRIVE_REMOVABLE;
    bool solidState = false;
    std::wstring volumeDevice(volumeName);
    volumeDevice.pop_back();
    auto h = CreateFileW(volumeDevice.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        STORAGE_PROPERTY_QUERY query{StorageDeviceProperty, PropertyStandardQuery, {}};
        alignas(STORAGE_DEVICE_DESCRIPTOR) std::array<unsigned char, 1024> buffer{};
        DWORD received{};
        if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query), buffer.data(), static_cast<DWORD>(buffer.size()), &received, nullptr) &&
            received >= sizeof(STORAGE_DEVICE_DESCRIPTOR)) {
            auto bus = reinterpret_cast<const STORAGE_DEVICE_DESCRIPTOR*>(buffer.data())->BusType;
            external = external || bus == BusTypeUsb || bus == BusType1394 || bus == BusTypeSd || bus == BusTypeMmc;
        }
        query.PropertyId = StorageDeviceSeekPenaltyProperty;
        DEVICE_SEEK_PENALTY_DESCRIPTOR penalty{};
        if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query), &penalty, sizeof(penalty), &received, nullptr) &&
            received >= sizeof(penalty)) solidState = !penalty.IncursSeekPenalty;
        CloseHandle(h);
    }
    return {fs::path(mount), utf8(fs::path(volumeName)) + "|" + std::to_string(serial), utf8(fs::path(label)),
        folded(utf8(fs::path(format))), free.QuadPart, total.QuadPart, external, solidState};
#else
    struct statfs info{};
    if (statfs(p.c_str(), &info) != 0) fail("statfs");
    return {fs::path(info.f_mntonname), std::to_string(info.f_fsid.val[0]), fs::path(info.f_mntonname).filename().string(),
        info.f_fstypename, static_cast<uint64_t>(info.f_bavail) * info.f_bsize,
        static_cast<uint64_t>(info.f_blocks) * info.f_bsize, false, false};
#endif
}
std::optional<fs::path> findVolume(std::string_view id) {
#ifdef _WIN32
    auto split = id.rfind('|');
    if (split == id.npos) return {};
    auto volume = path(id.substr(0, split)).make_preferred().wstring();
    wchar_t mounts[32768]{};
    DWORD needed{};
    if (GetVolumePathNamesForVolumeNameW(volume.c_str(), mounts, static_cast<DWORD>(std::size(mounts)), &needed) && mounts[0]) {
        auto mount = fs::path(mounts);
        if (inspect(mount).id == id) return mount;
    }
#else
    (void)id;
#endif
    return {};
}
void eject(const Volume& volume) {
#ifdef _WIN32
    require(volume.external, "只能推出已验证的外置硬盘");
    auto guid = path(volume.id.substr(0, volume.id.rfind('|'))).make_preferred().wstring();
    if (!guid.empty() && guid.back() == L'\\') guid.pop_back();
    auto number = [](const std::wstring& device) -> std::optional<DWORD> {
        auto h = CreateFileW(device.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) return {};
        STORAGE_DEVICE_NUMBER info{};
        DWORD read{};
        auto ok = DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, nullptr, 0, &info, sizeof(info), &read, nullptr);
        CloseHandle(h);
        if (!ok || info.DeviceType != FILE_DEVICE_DISK) return {};
        return info.DeviceNumber;
    };
    auto disk = number(guid);
    require(disk.has_value(), "无法定位外置设备");
    constexpr GUID diskInterface{0x53f56307, 0xb6bf, 0x11d0, {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}};
    auto devices = SetupDiGetClassDevsW(&diskInterface, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE) fail("SetupDiGetClassDevsW");
    std::optional<DEVINST> instance;
    for (DWORD i = 0;; ++i) {
        SP_DEVICE_INTERFACE_DATA item{sizeof(item)};
        if (!SetupDiEnumDeviceInterfaces(devices, nullptr, &diskInterface, i, &item)) break;
        DWORD needed{};
        SetupDiGetDeviceInterfaceDetailW(devices, &item, nullptr, 0, &needed, nullptr);
        if (needed < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<unsigned char> bytes(needed);
        auto detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(bytes.data());
        detail->cbSize = sizeof(*detail);
        SP_DEVINFO_DATA info{sizeof(info)};
        if (SetupDiGetDeviceInterfaceDetailW(devices, &item, detail, needed, nullptr, &info) && number(detail->DevicePath) == disk) {
            instance = info.DevInst;
            break;
        }
    }
    SetupDiDestroyDeviceInfoList(devices);
    require(instance.has_value(), "外置硬盘已断开");
    PNP_VETO_TYPE veto{};
    wchar_t reason[MAX_PATH]{};
    auto result = CM_Request_Device_EjectW(*instance, &veto, reason, MAX_PATH, 0);
    require(result == CR_SUCCESS, "Windows 未能推出硬盘。请关闭占用此硬盘的程序后重试");
#else
    (void)volume;
    throw std::runtime_error("安全推出需要 Windows");
#endif
}
}
