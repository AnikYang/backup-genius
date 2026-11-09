#pragma once

#include "Store.h"
#include "Watch.h"
#include <atomic>
#include <chrono>

namespace bg {
enum class SyncState { unconfigured, disconnected, ready, checking, syncing, recovering, verifying,
                       upToDate, paused, needsAttention, takeoverRequired };
struct SyncProgress {
    SyncState state{SyncState::unconfigured};
    int64_t examined{}, planned{}, processed{}, skipped{}, tracked{}, unmanaged{}, issues{};
    int64_t sourceRead{}, targetRead{}, latestWritten{}, historyWritten{};
    double checkingSeconds{}, elapsedSeconds{};
    std::string message, currentPath;
};
struct BackupJob {
    std::string id, volume, format, relative, sourceId;
    fs::path source, target;
    bool automatic{true};
    bool restoreOnly{};
};
struct Presentation {
    BackupJob job;
    std::optional<Volume> volume;
    SyncProgress progress;
};
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
    explicit SyncEngine(fs::path storage, Progress = {}, bool allowInternal = false, Fault = {});
    ~SyncEngine();
    void start();
    void configure(const fs::path& source, const fs::path& target, bool automatic);
    void openExisting(const fs::path& target);
    void setAutomatic(bool value);
    void poll();
    SyncProgress sync(bool verify = false);
    void requestPause();
    void pause();
    void resume();
    void safeEject();
    fs::path restore(const fs::path&, std::string_view version = {});
    TakeoverPreview previewTakeover(const fs::path&);
    void confirmTakeover(std::string_view preview, const std::map<std::string, AlignmentChoice>&);
    Json activities();
    Json history();
    const Presentation& presentation() const { return view_; }
    void recordChanges(const Changes&, bool target = false);
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
    Fault fault_;
    std::string host_;
    Presentation view_;
    bool allowInternal_, suppress_{}, sourceGap_{}, verifyAttempted_{};
    std::atomic_bool paused_{};
    std::chrono::steady_clock::time_point published_{}, lastPollScan_{}, lastAttempt_{}, lastMaintenance_{};
};
}
