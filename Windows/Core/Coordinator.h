#pragma once

#include "Engine.h"
#include <mutex>
#include <set>

namespace bg {
struct SetupRow {
    std::string id, name, group, previous, sourceId;
    fs::path source;
    std::string folder() const { return join(group, name); }
};
struct SetupPreview {
    std::string id;
    Volume volume;
    std::vector<SetupRow> rows;
};

class BackupCoordinator {
public:
    explicit BackupCoordinator(fs::path storage, Progress = {}, bool allowInternal = false,
                               std::function<void(SetInterruption)> = {}, std::function<void()> changesReady = {});
    void start();
    bool offerGuide();
    void poll();
    void volumesDidChange(const std::vector<fs::path>& mounts = {}, bool removed = false);
    SetupPreview previewSetup(const fs::path& disk, const std::vector<fs::path>& sources);
    void confirmSetup(std::string_view preview, const std::map<std::string, std::string>& groups, bool automatic, bool eject);
    void openExisting(const fs::path& target);
    void select(std::string id);
    void setEnabled(bool);
    void setAutomatic(bool);
    void setAskOnConnect(bool);
    void respondToBackupPrompt(std::string_view id, bool backup);
    void setEjectAfterBackup(bool);
    void setMedium(std::optional<StorageMedium>, bool source = false);
    SyncProgress sync(bool verify = false);
    void requestPause();
    void pause();
    void resume();
    void safeEject();
    fs::path restore(const fs::path& out, std::string_view version = {});
    Json activities() { return selected().activities(); }
    Json history() { return selected().history(); }
    TakeoverPreview previewTakeover(const fs::path& folder) { return selected().previewTakeover(folder); }
    void confirmTakeover(std::string_view id, const std::map<std::string, AlignmentChoice>& choices);
    Presentation presentation() const;
private:
    struct Connection {
        fs::path mount;
        std::string name;
        bool allowed{};
        std::string prompt;
    };
    struct Binding {
        std::string volume;
        fs::path mount;
        std::vector<std::string> jobs;
        Json document() const;
        static Binding load(const Json&);
    };
    SyncEngine& selected();
    SyncEngine* engine(std::string_view) const;
    std::vector<SyncEngine*> all() const;
    std::optional<FolderMapping> mapping(const BackupJob&) const;
    void publish(bool force = true);
    void publishTransfer(std::string_view job, const SyncProgress&);
    void reconnect();
    void refreshConnections();
    void considerConnection(const Volume&);
    std::optional<Volume> connectedVolume(std::string_view disk, const fs::path& previous);
    bool writable(const BackupJob&) const;
    void attach(const BackupSet&, BackupSetStore&);
    void loadEngines(std::string_view set, const Binding&);
    void finalize(const BackupSet&, const Binding&, const std::vector<BackupJob>&);
    void alignFolderName(SyncEngine&);
    void ensureWriter(std::string_view);
    SyncProgress runDisk(std::string_view disk, bool verify, const std::map<std::string, bool>* requests);
    void ejectDisk(std::string_view disk);

    fs::path root_;
    Progress notify_;
    std::function<void()> changesReady_;
    bool allowInternal_;
    std::function<void(SetInterruption)> fault_;
    std::unique_ptr<SyncEngine> legacy_;
    std::unique_ptr<Index> settings_;
    std::string host_, selected_, running_;
    std::set<std::string> confirmedDisks_;
    std::map<std::string, Binding> bindings_;
    std::map<std::string, BackupSet> sets_;
    std::map<std::string, std::unique_ptr<BackupSetStore>> stores_;
    std::map<std::string, std::unique_ptr<SyncEngine>> engines_;
    std::map<std::string, StorageMedium> media_;
    std::map<std::string, SyncProgress> diskProgress_;
    std::map<std::string, fs::path> ejected_;
    std::map<std::string, Connection> connections_;
    std::optional<SetupPreview> preview_;
    std::optional<BackupSet> previewSet_;
    std::atomic_bool paused_{};
    std::atomic<SyncEngine*> active_{};
    bool busy_{};
    bool askOnConnect_{true};
    std::mutex publishedMutex_;
    Presentation publishedView_;
    std::chrono::steady_clock::time_point lastPublished_{};
};
}
