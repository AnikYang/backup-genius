#pragma once

#include "Store.h"
#include "Watch.h"
#include "BackupSet.h"
#include <atomic>
#include <chrono>
#include <mutex>

namespace bg {
enum class SyncState { unconfigured, disconnected, ready, checking, syncing, recovering, verifying,
                       upToDate, paused, needsAttention, takeoverRequired };
struct SyncProgress {
    SyncState state{SyncState::unconfigured};
    int64_t examined{}, planned{}, processed{}, skipped{}, tracked{}, unmanaged{}, issues{};
    int64_t sourceRead{}, targetRead{}, latestWritten{}, historyWritten{};
    int64_t sourceReadRequests{}, targetReadRequests{}, latestWriteRequests{}, ioBufferBudget{};
    double checkingSeconds{}, elapsedSeconds{};
    std::optional<double> writeBytesPerSecond, estimatedSecondsRemaining;
    std::string message, currentPath;
    int64_t pendingSourcePaths{};
    bool sourceNeedsScan{}, sourceObserving{};
};
struct BackupJob {
    std::string id, volume, format, relative, sourceId;
    fs::path source, target;
    bool automatic{true};
    bool restoreOnly{};
    std::string set;
    bool ejectAfterBackup{};
    std::string volumeName;
};
struct FolderStatus {
    BackupJob job;
    std::optional<FolderMapping> mapping;
    SyncProgress progress;
};
struct BackupPrompt {
    std::string id, disk, name;
    size_t folders{};
    bool operator==(const BackupPrompt&) const = default;
};
struct BackupDiskStatus {
    std::string id, name;
    fs::path mount;
    bool connected{};
};
struct Presentation {
    BackupJob job;
    std::optional<Volume> volume;
    SyncProgress progress;
    std::vector<FolderStatus> folders;
    std::vector<BackupDiskStatus> disks;
    std::string runningFolder;
    std::string runningDisk;
    bool busy{};
    bool askOnConnect{true}, selectedDiskConnected{};
    std::vector<BackupPrompt> backupPrompts;
    std::string runningJob;
    std::optional<StorageDeviceInfo> sourceDevice;
    std::optional<StorageMedium> mediumOverride, sourceMediumOverride;
};
Json jobJSON(const BackupJob&);
BackupJob loadJob(const Json&);
enum class AlignmentKind { receive, send, conflict, blocked };
enum class AlignmentChoice { local, disk, both };
struct AlignmentChange {
    std::string path;
    AlignmentKind kind{};
    bool canKeepBoth{};
};
struct TakeoverPreview {
    std::string id;
    int64_t generation{};
    std::vector<AlignmentChange> changes;
    bool resuming{};
};
using Progress = std::function<void(const Presentation&)>;

// Calls other than requestPause are serialized on the application's worker.
class SyncEngine {
public:
    explicit SyncEngine(fs::path storage, Progress = {}, bool allowInternal = false, Fault = {}, std::string host = {},
                        std::function<void()> changesReady = {});
    ~SyncEngine();
    void start(bool connect = true);
    void refreshConnection();
    void disconnect();
    void configure(const fs::path& source, const fs::path& target, bool automatic);
    void openExisting(const fs::path& target);
    void setAutomatic(bool value);
    std::optional<bool> poll(bool automatic = true);
    SyncProgress sync(bool verify = false);
    void requestPause();
    void pause();
    void resume();
    void safeEject();
    fs::path restore(const fs::path&, std::string_view version = {}, std::string_view point = {});
    TakeoverPreview previewTakeover(const fs::path&);
    void confirmTakeover(std::string_view preview, const std::map<std::string, AlignmentChoice>&);
    Json activities();
    Json history();
    Json restorePoints();
    void observeSource();
    const Presentation& presentation() const { return view_; }
    void recordChanges(const Changes&, bool target = false);
    void installMember(BackupJob);
    void bindMember(std::optional<Volume>, std::string relative = {}, const fs::path& source = {});
    fs::path memberSource() const;
    bool hasPendingChanges();
    void releaseForEjection();
    void report(const std::exception& e) { fail(e); }
    void clearPause() { paused_ = false; }
    void allowReconnect() { suppress_ = false; }
    void setEjectAfterBackup(bool value);
    void setMedia(std::map<std::string, StorageMedium> values) { media_ = std::move(values); }
private:
    struct Draft;
    void saveJob();
    void setJob(BackupJob);
    void refresh();
    void publish(bool force = false);
    void drain();
    bool requiresTakeover();
    Tree sourceTree() const;
    Records diskSnapshot();
    SyncProgress run(bool verify);
    void fail(const std::exception&);

    fs::path storage_;
    std::unique_ptr<Index> settings_, index_;
    std::unique_ptr<Repository> repo_;
    std::unique_ptr<DirectoryWatch> sourceWatch_, targetWatch_;
    std::unique_ptr<Draft> draft_;
    Progress notify_;
    std::function<void()> changesReady_;
    Fault fault_;
    std::string host_;
    std::optional<Volume> mappedVolume_;
    std::map<std::string, StorageMedium> media_;
    std::optional<StorageDeviceInfo> sourceDevice_;
    Presentation view_;
    bool allowInternal_, suppress_{}, sourceGap_{}, verifyAttempted_{};
    std::atomic_bool paused_{};
    std::mutex publishedMutex_;
    Presentation publishedView_;
    std::chrono::steady_clock::time_point published_{}, lastPollScan_{}, lastMaintenance_{};
};
}
