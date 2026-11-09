#include "Watch.h"

#include <atomic>
#include <array>
#include <future>
#include <mutex>
#include <thread>
#include <utility>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winioctl.h>
#endif

namespace bg {
struct DirectoryWatch::State {
    std::mutex mutex;
    Changes changes;
    std::atomic_bool active{false};
    std::jthread thread;
};
DirectoryWatch::DirectoryWatch(const fs::path& root) : state_(std::make_unique<State>()) {
#ifdef _WIN32
    auto state = state_.get();
    auto folder = Tree(root).checked({});
    std::promise<void> firstRead;
    auto ready = firstRead.get_future();
    state->thread = std::jthread([state, folder, firstRead = std::move(firstRead)](std::stop_token stop) mutable {
        auto h = CreateFileW(folder.c_str(), FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED |
                             FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (h == INVALID_HANDLE_VALUE) { firstRead.set_value(); return; }
        auto event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!event) { CloseHandle(h); firstRead.set_value(); return; }
        alignas(DWORD) std::array<unsigned char, 65536> buffer{};
        bool starting = true;
        while (!stop.stop_requested()) {
            OVERLAPPED operation{};
            operation.hEvent = event;
            ResetEvent(event);
            const auto mask = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE |
                FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_CREATION |
                FILE_NOTIFY_CHANGE_SECURITY;
            const bool posted = ReadDirectoryChangesW(h, buffer.data(), static_cast<DWORD>(buffer.size()), TRUE, mask, nullptr, &operation, nullptr) != FALSE;
            if (starting) {
                state->active = posted;
                firstRead.set_value();
                starting = false;
            }
            if (!posted) break;
            while (!stop.stop_requested() && WaitForSingleObject(event, 100) == WAIT_TIMEOUT) {}
            if (stop.stop_requested()) {
                CancelIoEx(h, &operation);
                DWORD ignored{};
                GetOverlappedResult(h, &operation, &ignored, TRUE);
                break;
            }
            DWORD count{};
            if (!GetOverlappedResult(h, &operation, &count, FALSE) || count == 0) {
                std::lock_guard lock(state->mutex);
                state->changes.full = true;
                if (GetLastError() == ERROR_INVALID_HANDLE || GetLastError() == ERROR_DEVICE_NOT_CONNECTED) break;
                continue;
            }
            try {
                std::lock_guard lock(state->mutex);
                size_t offset = 0;
                while (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) <= count) {
                    const auto* item = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(buffer.data() + offset);
                    if (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) + item->FileNameLength > count) {
                        state->changes.full = true;
                        break;
                    }
                    std::wstring name(item->FileName, item->FileNameLength / sizeof(wchar_t));
                    auto relative = utf8(fs::path(name));
                    if (validPath(relative)) state->changes.paths[relative] |= item->Action == FILE_ACTION_MODIFIED ? contentChange : nameChange;
                    if (item->NextEntryOffset == 0) break;
                    offset += item->NextEntryOffset;
                }
                if (state->changes.paths.size() > 100000) { state->changes.paths.clear(); state->changes.full = true; }
            } catch (...) {
                std::lock_guard lock(state->mutex);
                state->changes.full = true;
            }
        }
        state->active = false;
        {
            std::lock_guard lock(state->mutex);
            state->changes.full = true;
        }
        CloseHandle(event);
        CloseHandle(h);
    });
    ready.get();
#else
    (void)root;
#endif
}
DirectoryWatch::~DirectoryWatch() = default;
Changes DirectoryWatch::take() {
    std::lock_guard lock(state_->mutex);
    return std::exchange(state_->changes, {});
}
bool DirectoryWatch::alive() const { return state_->active; }

#ifdef _WIN32
namespace {
#ifdef __MINGW32__
using JournalInfo = USN_JOURNAL_DATA;
using JournalRead = READ_USN_JOURNAL_DATA;
using JournalRecord = USN_RECORD;
#else
using JournalInfo = USN_JOURNAL_DATA_V0;
using JournalRead = READ_USN_JOURNAL_DATA_V0;
using JournalRecord = USN_RECORD_V2;
#endif
struct Handle {
    HANDLE value{INVALID_HANDLE_VALUE};
    ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    explicit operator bool() const { return value != INVALID_HANDLE_VALUE; }
};
Handle journalHandle(const fs::path& root) {
    auto volume = inspect(root);
    if (volume.format != "ntfs") return {};
    auto id = path(volume.id.substr(0, volume.id.rfind('|'))).make_preferred().wstring();
    if (!id.empty() && id.back() == L'\\') id.pop_back();
    return {CreateFileW(id.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        nullptr, OPEN_EXISTING, 0, nullptr)};
}
std::optional<JournalInfo> queryJournal(HANDLE handle) {
    JournalInfo data{};
    DWORD bytes{};
    if (!DeviceIoControl(handle, FSCTL_QUERY_USN_JOURNAL, nullptr, 0, &data, sizeof(data), &bytes, nullptr) ||
        bytes < sizeof(data)) return {};
    return data;
}
}
#endif

std::optional<Cursor> currentCursor(const fs::path& root) {
#ifdef _WIN32
    try {
        auto handle = journalHandle(root);
        if (!handle) return {};
        auto data = queryJournal(handle.value);
        if (data) return Cursor{data->UsnJournalID, data->NextUsn};
    } catch (...) {}
#else
    (void)root;
#endif
    return {};
}
std::optional<Changes> changesSince(const fs::path& root, Cursor from, Cursor to) {
#ifdef _WIN32
    try {
        auto handle = journalHandle(root);
        if (!handle || from.journal != to.journal || from.next > to.next) return {};
        auto info = queryJournal(handle.value);
        if (!info || info->UsnJournalID != to.journal || from.next < info->FirstUsn || from.next < info->LowestValidUsn) return {};
        JournalRead read{};
        read.UsnJournalID = to.journal;
        read.StartUsn = from.next;
        read.ReasonMask = 0xFFFFFFFFu;
        alignas(JournalRecord) std::array<unsigned char, 65536> buffer{};
        Changes result;
        auto prefix = folded(utf8(Tree(root).checked({})));
        for (int page = 0; read.StartUsn < to.next && page < 64; ++page) {
            DWORD bytes{};
            if (!DeviceIoControl(handle.value, FSCTL_READ_USN_JOURNAL, &read, sizeof(read), buffer.data(),
                                 static_cast<DWORD>(buffer.size()), &bytes, nullptr) || bytes < sizeof(USN)) return {};
            const auto next = *reinterpret_cast<const USN*>(buffer.data());
            for (size_t offset = sizeof(USN); offset < bytes;) {
                if (bytes - offset < offsetof(JournalRecord, FileName)) return {};
                const auto* item = reinterpret_cast<const JournalRecord*>(buffer.data() + offset);
                if (item->MajorVersion != 2 || item->RecordLength < offsetof(JournalRecord, FileName) ||
                    item->RecordLength > bytes - offset || item->FileNameOffset + item->FileNameLength > item->RecordLength) return {};
                offset += item->RecordLength;
                if (item->Usn >= to.next) break;
                if (item->Reason & USN_REASON_CLOSE && (item->Reason & ~USN_REASON_CLOSE) == 0) continue;
                FILE_ID_DESCRIPTOR id{};
                id.dwSize = sizeof(id);
                id.Type = FileIdType;
                id.FileId.QuadPart = static_cast<LONGLONG>(item->ParentFileReferenceNumber);
                Handle directory{OpenFileById(handle.value, &id, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                              nullptr, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)};
                if (!directory) return {};
                std::wstring folder(32768, L'\0');
                auto length = GetFinalPathNameByHandleW(directory.value, folder.data(), static_cast<DWORD>(folder.size()), FILE_NAME_NORMALIZED);
                if (length == 0 || length >= folder.size()) return {};
                folder.resize(length);
                auto fullParent = utf8(fs::path(folder));
                auto match = folded(fullParent);
                if (!inside(match, prefix)) continue;
                auto base = match == prefix ? "" : fullParent.substr(prefix.size() + 1);
                const auto* filename = reinterpret_cast<const wchar_t*>(reinterpret_cast<const unsigned char*>(item) + item->FileNameOffset);
                auto rel = join(base, utf8(fs::path(std::wstring(filename, item->FileNameLength / sizeof(wchar_t)))));
                if (validPath(rel)) {
                    constexpr DWORD names = USN_REASON_FILE_CREATE | USN_REASON_FILE_DELETE | USN_REASON_RENAME_OLD_NAME | USN_REASON_RENAME_NEW_NAME;
                    const auto content = item->Reason & ~(names | USN_REASON_CLOSE);
                    if (item->Reason & names) result.paths[rel] |= nameChange;
                    if (content) result.paths[rel] |= contentChange;
                }
            }
            if (next <= read.StartUsn) return {};
            read.StartUsn = next;
        }
        if (read.StartUsn < to.next) return {};
        return result;
    } catch (...) { return {}; }
#else
    (void)root; (void)from; (void)to;
#endif
    return {};
}
}
