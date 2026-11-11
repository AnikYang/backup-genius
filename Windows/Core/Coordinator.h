#pragma once

#include "Engine.h"
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
                               std::function<void(SetInterruption)> = {});
    void start();
    bool offerGuide();
    void poll();
    void volumesDidChange();
    SetupPreview previewSetup(const fs::path& disk, const std::vector<fs::path>& sources);
    void confirmSetup(std::string_view preview, const std::map<std::string, std::string>& groups, bool automatic, bool eject);
    void openExisting(const fs::path& target);
    void select(std::string id);
    void setEnabled(bool);
    void setAutomatic(bool);
    void setEjectAfterBackup(bool);
    void setMedium(std::optional<StorageMedium>, bool source = false);
    SyncProgress sync(bool verify = false);
    void requestPause();
    void pause();
    void resume();
    void safeEject();
    fs::path restore(const fs::path& out, std::string_view version = {}) { return selected().restore(out, version); }
    Json activities() { return selected().activities(); }
    Json history() { return selected().history(); }
    TakeoverPreview previewTakeover(const fs::path& folder) { return selected().previewTakeover(folder); }
    void confirmTakeover(std::string_view id, const std::map<std::string, AlignmentChoice>& choices) {
        selected().confirmTakeover(id, choices);
    }
    Presentation presentation() const;
private:
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
    void reconnect(bool updateVolume = false);
    void attach(const BackupSet&, BackupSetStore&);
    void loadEngines(std::string_view set, const Binding&);
    void finalize(const BackupSet&, const Binding&, const std::vector<BackupJob>&);
    void alignFolderName(SyncEngine&);
    void ensureWriter(std::string_view);
    SyncProgress runDisk(std::string_view disk, bool verify, const std::map<std::string, bool>* requests);
    void ejectDisk(std::string_view disk);

    fs::path root_;
    Progress notify_;
    bool allowInternal_;
    std::function<void(SetInterruption)> fault_;
    std::unique_ptr<SyncEngine> legacy_;
    std::unique_ptr<Index> settings_;
    std::string host_, selected_, running_;
    std::map<std::string, Binding> bindings_;
    std::map<std::string, BackupSet> sets_;
    std::map<std::string, std::unique_ptr<BackupSetStore>> stores_;
    std::map<std::string, std::unique_ptr<SyncEngine>> engines_;
    std::map<std::string, StorageMedium> media_;
    std::map<std::string, SyncProgress> diskProgress_;
    std::set<std::string> ejected_;
    std::optional<SetupPreview> preview_;
    std::optional<BackupSet> previewSet_;
    std::atomic_bool paused_{};
    std::atomic<SyncEngine*> active_{};
    bool busy_{};
    std::chrono::steady_clock::time_point lastPublished_{};
};
}
