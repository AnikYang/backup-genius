#include "Coordinator.h"

#include <algorithm>
#include <stdexcept>

namespace bg {
namespace {
using Clock = std::chrono::steady_clock;
void require(bool result, const char* message) { if (!result) throw std::runtime_error(message); }
bool overlaps(const fs::path& lhs, const fs::path& rhs) {
    const auto a = folded(utf8(lhs)), b = folded(utf8(rhs));
    return inside(a, b) || inside(b, a);
}
std::string relativeToRoot(std::string_view folder) { return join(backupRoot, folder); }
BackupJob memberJob(const BackupSet& set, const FolderMapping& mapping, const Volume& volume, const SetupRow* row,
                    bool automatic = false, bool eject = false) {
    auto relative = relativeToRoot(mapping.folder);
    return {mapping.job, volume.id, volume.format, relative, row ? row->sourceId : "",
        row ? row->source : fs::path{}, representable(relative) ? volume.mount / path(relative) : volume.mount,
        automatic, !row, set.id, eject, volume.label};
}
void accumulate(SyncProgress& summary, const SyncProgress& value) {
    summary.examined += value.examined;
    summary.planned += value.planned;
    summary.processed += value.processed;
    summary.skipped += value.skipped;
    summary.tracked += value.tracked;
    summary.unmanaged += value.unmanaged;
    summary.issues += value.issues;
    summary.sourceRead += value.sourceRead;
    summary.targetRead += value.targetRead;
    summary.latestWritten += value.latestWritten;
    summary.historyWritten += value.historyWritten;
    summary.sourceReadRequests += value.sourceReadRequests;
    summary.targetReadRequests += value.targetReadRequests;
    summary.latestWriteRequests += value.latestWriteRequests;
    summary.ioBufferBudget = std::max(summary.ioBufferBudget, value.ioBufferBudget);
}
}
Json BackupCoordinator::Binding::document() const {
    return {{"volume", volume}, {"mount", utf8(mount)}, {"jobs", jobs}};
}
BackupCoordinator::Binding BackupCoordinator::Binding::load(const Json& json) {
    Binding result{json.at("volume"), path(json.at("mount").get<std::string>()), json.at("jobs")};
    for (auto& job : result.jobs) job = identifier(job);
    return result;
}
BackupCoordinator::BackupCoordinator(fs::path storage, Progress progress, bool allowInternal,
                                     std::function<void(SetInterruption)> fault, std::function<void()> changesReady)
    : root_(std::move(storage)), notify_(std::move(progress)), changesReady_(std::move(changesReady)),
      allowInternal_(allowInternal), fault_(std::move(fault)) {
    legacy_ = std::make_unique<SyncEngine>(root_, [this](const auto& value) {
        if (value.progress.writeBytesPerSecond) publishTransfer(value.job.id, value.progress);
        else publish(false);
    }, allowInternal_, Fault{}, std::string{}, changesReady_);
}
void BackupCoordinator::start() {
    if (settings_) return;
    legacy_->start(false);
    root_ = fs::canonical(root_);
    settings_ = std::make_unique<Index>(root_ / "settings.sqlite");
    host_ = identifier(settings_->get("settings", "host"));
    askOnConnect_ = settings_->get("settings", "askOnConnect") != false;
    for (const auto& [id, value] : settings_->all("sets")) {
        auto binding = Binding::load(value);
        bindings_[identifier(id)] = binding;
        const auto layout = settings_->get("setLayout", id);
        if (!layout.is_null()) sets_[id] = readSet(layout);
        loadEngines(id, binding);
    }
    for (const auto& [id, value] : settings_->all("setPending")) {
        if (!bindings_.contains(id)) bindings_[identifier(id)] = Binding::load(value.at("binding"));
    }
    for (const auto& [key, value] : settings_->all("media")) {
        media_[key] = value == "ssd" ? StorageMedium::ssd : StorageMedium::hdd;
    }
    for (const auto& [disk, value] : settings_->all("selectedFolders")) {
        if (value.is_string()) selectedFolders_[disk] = value.get<std::string>();
    }
    const auto savedSelection = settings_->get("settings", "selectedFolder");
    if (savedSelection.is_string() && engine(savedSelection.get<std::string>())) selected_ = savedSelection.get<std::string>();
    for (auto job : all()) job->setMedia(media_);
    refreshConnections();
    if (selected_.empty()) {
        const auto disks = presentation().disks;
        if (!disks.empty() && disks.front().connected) selectDisk(disks.front().id);
    }
    publish();
}
bool BackupCoordinator::offerGuide() {
    start();
    if (!presentation().folders.empty() || settings_->get("settings", "guideOffered") == true) return false;
    settings_->put("settings", "guideOffered", true);
    return true;
}
std::vector<SyncEngine*> BackupCoordinator::all() const {
    std::vector<SyncEngine*> jobs{legacy_.get()};
    for (const auto& [_, engine] : engines_) jobs.push_back(engine.get());
    return jobs;
}
SyncEngine* BackupCoordinator::engine(std::string_view id) const {
    if (id == legacy_->presentation().job.id) return legacy_.get();
    const auto found = engines_.find(std::string(id));
    return found == engines_.end() ? nullptr : found->second.get();
}
SyncEngine& BackupCoordinator::selected() {
    if (auto job = engine(selected_); job && !selected_.empty()) return *job;
    if (!legacy_->presentation().job.id.empty() || engines_.empty()) return *legacy_;
    return *engines_.begin()->second;
}
std::optional<FolderMapping> BackupCoordinator::mapping(const BackupJob& job) const {
    const auto set = sets_.find(job.set);
    if (set == sets_.end()) return {};
    for (const auto& map : set->second.mappings) if (map.job == job.id) return map;
    return {};
}
Presentation BackupCoordinator::presentation() const {
    const auto* selected = engine(selected_);
    if (!selected || selected_.empty())
        selected = !legacy_->presentation().job.id.empty() || engines_.empty() ? legacy_.get() : engines_.begin()->second.get();
    auto view = selected->presentation();
    view.askOnConnect = askOnConnect_;
    for (const auto& [disk, connection] : connections_) if (!connection.prompt.empty()) {
        size_t count = 0;
        for (auto job : all()) {
            const auto& entry = job->presentation().job;
            if (entry.volume == disk && writable(entry)) ++count;
        }
        if (count) view.backupPrompts.push_back({connection.prompt, disk, connection.name, count});
    }
    if (view.volume) {
        const auto setting = media_.find(folded(view.volume->device.id));
        if (setting != media_.end()) view.mediumOverride = setting->second;
    }
    if (view.sourceDevice) {
        const auto setting = media_.find(folded(view.sourceDevice->id));
        if (setting != media_.end()) view.sourceMediumOverride = setting->second;
    }
    std::map<std::string, BackupDiskStatus> disks;
    for (auto engine : all()) {
        const auto& snapshot = engine->presentation();
        const auto& job = snapshot.job;
        if (job.id.empty()) continue;
        view.folders.push_back({job, mapping(job), snapshot.progress});
        auto& disk = disks[job.volume];
        disk.id = job.volume;
        if (disk.name.empty()) disk.name = job.volumeName.empty() ? job.volume : job.volumeName;
        if (ejected_.contains(job.volume)) continue;
        if (auto connection = connections_.find(job.volume); connection != connections_.end()) {
            disk.connected = true;
            disk.mount = connection->second.mount;
            if (!connection->second.name.empty()) disk.name = connection->second.name;
        } else if (snapshot.volume) {
            disk.connected = true;
            disk.mount = snapshot.volume->mount;
            if (!snapshot.volume->label.empty()) disk.name = snapshot.volume->label;
        }
    }
    for (auto& [_, disk] : disks) view.disks.push_back(std::move(disk));
    std::sort(view.disks.begin(), view.disks.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.connected != rhs.connected) return lhs.connected;
        return std::tie(lhs.name, lhs.id) < std::tie(rhs.name, rhs.id);
    });
    view.selectedDiskConnected = std::any_of(view.disks.begin(), view.disks.end(), [&](const auto& disk) {
        return disk.id == view.job.volume && disk.connected;
    });
    std::sort(view.folders.begin(), view.folders.end(), [](const auto& lhs, const auto& rhs) {
        return std::tie(lhs.job.volume, lhs.job.relative) < std::tie(rhs.job.volume, rhs.job.relative);
    });
    if (auto active = active_.load(); busy_ && active) {
        view.runningDisk = active->presentation().job.volume;
        if (view.runningDisk == view.job.volume) {
            view.progress = active->presentation().progress;
            view.runningJob = active->presentation().job.id;
            if (view.progress.state == SyncState::ready) view.progress.state = SyncState::checking;
        }
    } else if (!view.job.set.empty() && view.volume && view.progress.state != SyncState::takeoverRequired &&
               view.progress.state != SyncState::paused && diskProgress_.contains(view.job.volume)) {
        view.progress = diskProgress_.at(view.job.volume);
    }
    view.busy = busy_;
    if (view.runningDisk == view.job.volume) view.runningFolder = running_;
    return view;
}
void BackupCoordinator::publish(bool force) {
    std::lock_guard lock(publishedMutex_);
    const auto time = Clock::now();
    if (notify_ && (force || time - lastPublished_ >= std::chrono::milliseconds(200))) {
        auto view = presentation();
        if (!view.runningJob.empty() && view.runningJob == publishedView_.runningJob &&
            view.progress.state == SyncState::syncing && publishedView_.progress.state == SyncState::syncing) {
            view.progress.writeBytesPerSecond = publishedView_.progress.writeBytesPerSecond;
            view.progress.estimatedSecondsRemaining = publishedView_.progress.estimatedSecondsRemaining;
        }
        lastPublished_ = time;
        publishedView_ = std::move(view);
        notify_(publishedView_);
    }
}
void BackupCoordinator::publishTransfer(std::string_view job, const SyncProgress& progress) {
    std::lock_guard lock(publishedMutex_);
    const auto time = Clock::now();
    if (!notify_ || publishedView_.runningJob != job || progress.state != SyncState::syncing ||
        time - lastPublished_ < std::chrono::milliseconds(200)) return;
    lastPublished_ = time;
    publishedView_.progress = progress;
    notify_(publishedView_);
}
void BackupCoordinator::select(std::string id) {
    auto* member = id.empty() ? nullptr : engine(id);
    if (!member) return;
    const auto& disk = member->presentation().job.volume;
    if (settings_) {
        settings_->transaction([&] {
            settings_->put("settings", "selectedFolder", id);
            settings_->put("selectedFolders", disk, id);
        });
    }
    selectedFolders_[disk] = id;
    selected_ = std::move(id);
    publish();
}
void BackupCoordinator::selectDisk(std::string_view disk) {
    const auto previous = selectedFolders_.find(std::string(disk));
    if (previous != selectedFolders_.end()) {
        if (const auto* member = engine(previous->second); member && member->presentation().job.volume == disk) {
            select(previous->second);
            return;
        }
    }
    const auto folders = presentation().folders;
    const auto matching = [&](const auto& folder) { return folder.job.volume == disk; };
    const auto enabled = std::find_if(folders.begin(), folders.end(), [&](const auto& folder) {
        return matching(folder) && writable(folder.job);
    });
    if (enabled != folders.end()) select(enabled->job.id);
    else if (const auto first = std::find_if(folders.begin(), folders.end(), matching); first != folders.end()) select(first->job.id);
}
void BackupCoordinator::loadEngines(std::string_view set, const Binding& binding) {
    for (const auto& id : binding.jobs) if (!engines_.contains(id)) {
        auto job = std::make_unique<SyncEngine>(root_ / "collections" / path(set) / path(id),
            [this](const auto& value) {
                if (value.progress.writeBytesPerSecond) publishTransfer(value.job.id, value.progress);
                else publish(false);
            }, allowInternal_, Fault{}, host_, changesReady_);
        auto& member = *job;
        engines_[id] = std::move(job);
        member.setMedia(media_);
        member.start(false);
    }
}
void BackupCoordinator::finalize(const BackupSet& set, const Binding& binding, const std::vector<BackupJob>& jobs) {
    for (const auto& job : jobs) {
        const auto location = root_ / "collections" / path(set.id) / path(job.id);
        fs::create_directories(location);
        Index state(location / "settings.sqlite");
        if (state.get("settings", "job").is_null()) state.put("settings", "job", jobJSON(job));
    }
    settings_->transaction([&] {
        settings_->put("sets", set.id, binding.document());
        settings_->put("setLayout", set.id, setDocument(set));
        settings_->remove("setPending", set.id);
    });
    bindings_[set.id] = binding;
    sets_[set.id] = set;
    loadEngines(set.id, binding);
}
void BackupCoordinator::attach(const BackupSet& set, BackupSetStore& store) {
    auto binding = bindings_.at(set.id);
    binding.mount = store.volume.mount;
    std::vector<BackupJob> missing;
    for (const auto& map : set.mappings) {
        if (std::find(binding.jobs.begin(), binding.jobs.end(), map.job) == binding.jobs.end()) {
            binding.jobs.push_back(map.job);
            missing.push_back(memberJob(set, map, store.volume, nullptr));
        }
    }
    if (!sets_.contains(set.id) || sets_.at(set.id) != set || !missing.empty() ||
        bindings_.at(set.id).mount != binding.mount) finalize(set, binding, missing);
    for (const auto& map : set.mappings) if (auto job = engine(map.job))
        job->bindMember(store.volume, relativeToRoot(map.folder));
}
bool BackupCoordinator::writable(const BackupJob& job) const {
    const auto map = mapping(job);
    return !job.id.empty() && !job.restoreOnly && (!map || map->enabled);
}
std::optional<Volume> BackupCoordinator::connectedVolume(std::string_view disk, const fs::path& previous) {
    try {
        auto volume = allowInternal_ ? std::optional(inspect(previous)) : findMountedVolume(disk);
        if (volume && volume->id == disk && (allowInternal_ || volume->external)) return volume;
    } catch (...) {}
    return {};
}
void BackupCoordinator::considerConnection(const Volume& volume) {
    if (ejected_.contains(volume.id)) return;
    const auto name = volume.label.empty() ? utf8(volume.mount) : volume.label;
    const auto [it, inserted] = connections_.try_emplace(volume.id, Connection{volume.mount, name, !askOnConnect_, {}});
    it->second.mount = volume.mount;
    it->second.name = name;
    if (inserted && askOnConnect_) it->second.prompt = uuid();
}
void BackupCoordinator::refreshConnections() {
    const auto& job = legacy_->presentation().job;
    if (!job.id.empty()) {
        const auto volume = connectedVolume(job.volume, job.target);
        if (volume) {
            if (!job.restoreOnly) considerConnection(*volume);
            if (!ejected_.contains(job.volume) && (job.restoreOnly || connections_.at(job.volume).allowed))
                legacy_->refreshConnection();
        } else {
            connections_.erase(job.volume);
            confirmedDisks_.erase(job.volume);
            ejected_.erase(job.volume);
            legacy_->disconnect();
        }
    }
    reconnect();
}
void BackupCoordinator::reconnect() {
    for (auto it = bindings_.begin(); it != bindings_.end();) {
        const auto id = it->first;
        const auto binding = it->second;
        ++it;
        auto volume = connectedVolume(binding.volume, binding.mount);
        if (!volume) {
            stores_.erase(id);
            ejected_.erase(binding.volume);
            connections_.erase(binding.volume);
            confirmedDisks_.erase(binding.volume);
            for (const auto& job : binding.jobs) if (auto member = engine(job)) member->disconnect();
            continue;
        }
        if (ejected_.contains(binding.volume)) continue;
        if (std::any_of(binding.jobs.begin(), binding.jobs.end(), [&](const auto& id) {
            const auto member = engine(id);
            return member && writable(member->presentation().job);
        })) {
            considerConnection(*volume);
            if (!connections_.at(binding.volume).allowed) continue;
        }
        try {
            require(allowInternal_ || volume->external, "请选择外置备份硬盘");
            auto& store = stores_[id];
            if (store && store->volume.mount != volume->mount) store.reset();
            if (!store) store = std::make_unique<BackupSetStore>(*volume, fault_);
            store->volume = *volume;
            const auto set = store->recover();
            const auto pending = settings_->get("setPending", id);
            if ((!set || set->id != id) && !pending.is_null() && settings_->get("sets", id).is_null()) {
                settings_->remove("setPending", id);
                stores_.erase(id);
                bindings_.erase(id);
                continue;
            }
            require(set && set->id == id, "找不到此硬盘上的备份集合");
            if (!pending.is_null()) {
                if (set->revision >= integer(pending.at("revision"))) {
                    const auto saved = Binding::load(pending.at("binding"));
                    require(std::all_of(saved.jobs.begin(), saved.jobs.end(), [&](const auto& job) {
                        return std::any_of(set->mappings.begin(), set->mappings.end(), [&](const auto& map) { return map.job == job; });
                    }), "磁盘上的映射与待保存的任务不符");
                    std::vector<BackupJob> jobs;
                    for (const auto& row : pending.at("jobs")) jobs.push_back(loadJob(row));
                    finalize(*set, saved, jobs);
                } else settings_->remove("setPending", id);
            }
            attach(*set, *store);
        } catch (const std::exception& e) {
            stores_.erase(id);
            for (const auto& job : binding.jobs) if (auto member = engine(job)) {
                member->bindMember({});
                member->report(e);
            }
        }
    }
}
void BackupCoordinator::volumesDidChange(const std::vector<fs::path>& mounts, bool removed) {
    start();
    const auto matches = [&](const fs::path& mount) {
        return std::any_of(mounts.begin(), mounts.end(), [&](const auto& root) {
            return folded(utf8(root)) == folded(utf8(mount));
        });
    };
    if (removed) {
        std::set<std::string> disconnected;
        for (const auto& [disk, connection] : connections_) if (matches(connection.mount)) disconnected.insert(disk);
        for (const auto& disk : disconnected) {
            connections_.erase(disk);
            confirmedDisks_.erase(disk);
            for (auto job : all()) if (job->presentation().job.volume == disk) job->disconnect();
            for (const auto& [id, binding] : bindings_) if (binding.volume == disk) stores_.erase(id);
        }
    } else {
        std::erase_if(ejected_, [&](const auto& entry) { return matches(entry.second); });
        for (auto job : all()) if (!ejected_.contains(job->presentation().job.volume)) job->allowReconnect();
    }
    refreshConnections();
    publish();
    poll();
}
SetupPreview BackupCoordinator::previewSetup(const fs::path& disk, const std::vector<fs::path>& sources) {
    start();
    const Tree root(disk);
    auto volume = inspect(root.root());
    require((allowInternal_ || volume.external) && root.root() == Tree(volume.mount).root(), "请选择外置硬盘的根目录");
    require(volume.format == "ntfs" || volume.format == "exfat", "请选择 NTFS 或 exFAT 硬盘");
    require(!sources.empty(), "请选择至少一个源文件夹");
    const auto existing = BackupSetStore::read(root, volume.format);
    SetupPreview result{uuid(), volume, {}};
    std::vector<fs::path> selected;
    if (existing) for (const auto& map : existing->mappings) {
        fs::path source;
        if (const auto job = engine(map.job); job && !job->presentation().job.restoreOnly) {
            source = job->presentation().job.source;
            selected.push_back(source);
        }
        result.rows.push_back({map.id, name(map.folder), parent(map.folder), map.folder, "", source});
    }
    for (const auto& url : sources) {
        const Tree source(url);
        require(std::none_of(selected.begin(), selected.end(), [&](const auto& item) { return overlaps(item, source.root()); }),
                "已选文件夹包含重复或父子目录");
        require(!overlaps(source.root(), root_ ) && !overlaps(source.root(), root.root() / path(backupRoot)) &&
                !overlaps(source.root(), root.root() / path(storageFolder)), "源文件夹与备份位置重叠");
        selected.push_back(source.root());
        result.rows.push_back({uuid(), utf8(source.root().filename()), "", "", source.identity().identity, source.root()});
    }
    std::map<std::string, size_t> counts;
    std::set<std::string> direct, used;
    for (const auto& row : result.rows) ++counts[folded(row.name)];
    for (const auto& row : result.rows) {
        if (row.group.empty() && counts.at(folded(row.name)) == 1) direct.insert(folded(row.name));
        if (!row.group.empty()) used.insert(folded(row.folder()));
    }
    for (auto& row : result.rows) if (row.group.empty() && counts.at(folded(row.name)) > 1) {
        auto base = utf8(row.source.parent_path().filename());
        if (base.empty() || backupControl(base)) base = "来源";
        row.group = base;
        for (size_t suffix = 2; direct.contains(folded(row.group)) || used.contains(folded(row.folder())); ++suffix)
            row.group = base + " " + std::to_string(suffix);
        used.insert(folded(row.folder()));
    }
    previewSet_ = existing;
    preview_ = result;
    return result;
}
void BackupCoordinator::ensureWriter(std::string_view id) {
    const auto member = engine(id);
    require(member && member->presentation().volume && !member->presentation().job.restoreOnly &&
        member->presentation().progress.state != SyncState::takeoverRequired, "请先在本机接管需要调整位置的备份文件夹");
}
void BackupCoordinator::confirmSetup(std::string_view id, const std::map<std::string, std::string>& groups,
                                     bool automatic, bool ejectAfter) {
    require(preview_ && preview_->id == id, "请重新预览备份映射");
    auto volume = inspect(preview_->volume.mount);
    require(volume.id == preview_->volume.id, "备份硬盘已更换");
    auto set = previewSet_.value_or(BackupSet{uuid(), volume.format, 0, {}});
    const auto old = set;
    auto temporary = stores_.contains(set.id) ? nullptr : std::make_unique<BackupSetStore>(volume, fault_);
    auto& store = temporary ? *temporary : *stores_.at(set.id);
    require(store.recover() == previewSet_, "备份映射已改变，请重新预览");
    require(set.revision < INT64_MAX, "备份集合的代次已满");
    ++set.revision;
    set.mappings.clear();
    auto binding = bindings_.contains(set.id) ? bindings_.at(set.id) : Binding{volume.id, volume.mount, {}};
    std::vector<Json> additions;
    std::vector<SetMove> moves;
    std::vector<BackupJob> jobs;
    for (auto row : preview_->rows) {
        if (auto group = groups.find(row.id); group != groups.end()) {
            require(!group->second.empty() && parent(group->second).empty() && representable(group->second), "请输入有效的来源分组名称");
            row.group = group->second;
        }
        if (!row.previous.empty()) {
            auto map = *std::find_if(old.mappings.begin(), old.mappings.end(), [&](const auto& entry) { return entry.id == row.id; });
            if (map.folder != row.folder()) {
                ensureWriter(map.job);
                moves.push_back({map.folder, row.folder(), map.job});
                map.folder = row.folder();
            }
            set.mappings.push_back(std::move(map));
        } else {
            const Tree source(row.source);
            require(source.identity().identity == row.sourceId, "源文件夹已移动，请重新选择");
            require(representable(row.folder()), "备份文件夹名称无效");
            FolderMapping map{row.id, uuid(), row.folder(), true};
            set.mappings.push_back(map);
            additions.push_back({{"version", 2}, {"job", map.job}, {"format", volume.format},
                {"initialWriter", host_}, {"legacyGeneration", 0}});
            jobs.push_back(memberJob(set, map, volume, &row, automatic, ejectAfter));
            binding.jobs.push_back(map.job);
        }
    }
    auto configs = Json::array();
    for (const auto& job : jobs) configs.push_back(jobJSON(job));
    settings_->put("setPending", set.id, {{"binding", binding.document()}, {"jobs", configs}, {"revision", set.revision}});
    bindings_[set.id] = bindings_.contains(set.id) ? bindings_.at(set.id) : binding;
    if (temporary) stores_[set.id] = std::move(temporary);
    for (const auto& move : moves) if (auto job = engine(move.job)) job->bindMember({});
    store.apply({old.revision, set, additions, moves});
    finalize(set, binding, jobs);
    attach(set, store);
    connections_[volume.id] = {volume.mount, volume.label, true, {}};
    if (!jobs.empty()) select(jobs.front().id);
    preview_.reset();
    previewSet_.reset();
    paused_ = false;
    for (auto job : all()) job->clearPause();
    sync();
}
void BackupCoordinator::openExisting(const fs::path& target) {
    start();
    const auto volume = inspect(target);
    const Tree disk(volume.mount);
    if (folded(utf8(target.lexically_normal())) != folded(utf8((volume.mount / path(backupRoot)).lexically_normal()))) {
        legacy_->openExisting(target);
        select(legacy_->presentation().job.id);
        return;
    }
    require(allowInternal_ || volume.external, "请选择外置备份硬盘");
    const auto current = BackupSetStore::read(disk, volume.format);
    auto temporary = current && stores_.contains(current->id) ? nullptr : std::make_unique<BackupSetStore>(volume, fault_);
    auto& store = temporary ? *temporary : *stores_.at(current->id);
    const auto set = store.recover();
    require(set.has_value(), "这块硬盘没有 BackupGenius 备份集合");
    if (!bindings_.contains(set->id)) {
        Binding binding{volume.id, volume.mount, {}};
        std::vector<BackupJob> jobs;
        for (const auto& map : set->mappings) {
            binding.jobs.push_back(map.job);
            jobs.push_back(memberJob(*set, map, volume, nullptr));
        }
        finalize(*set, binding, jobs);
    }
    attach(*set, store);
    if (temporary) stores_[set->id] = std::move(temporary);
    select(set->mappings.front().job);
}
void BackupCoordinator::setEnabled(bool enabled) {
    const auto job = selected().presentation().job;
    ensureWriter(job.id);
    auto set = sets_.at(job.set);
    const auto base = set.revision;
    require(base < INT64_MAX, "备份集合的代次已满");
    ++set.revision;
    for (auto& map : set.mappings) if (map.job == job.id) map.enabled = enabled;
    auto& store = *stores_.at(set.id);
    store.apply({base, set, {}, {}});
    attach(set, store);
    publish();
}
void BackupCoordinator::setAutomatic(bool value) { selected().setAutomatic(value); publish(); }
fs::path BackupCoordinator::restore(const fs::path& out, std::string_view version, std::string_view point) {
    auto& member = selected();
    const auto job = member.presentation().job;
    if (!member.presentation().volume && !job.set.empty() && connections_.contains(job.volume)) {
        const auto volume = connectedVolume(job.volume, connections_.at(job.volume).mount);
        require(volume.has_value(), "硬盘未连接");
        openExisting(volume->mount / path(backupRoot));
        select(job.id);
    }
    return member.restore(out, version, point);
}
void BackupCoordinator::confirmTakeover(std::string_view id, const std::map<std::string, AlignmentChoice>& choices) {
    auto& member = selected();
    member.confirmTakeover(id, choices);
    if (const auto& volume = member.presentation().volume) {
        connections_[volume->id] = {volume->mount, volume->label, true, {}};
    }
    publish();
    poll();
}
void BackupCoordinator::setAskOnConnect(bool value) {
    start();
    settings_->put("settings", "askOnConnect", value);
    askOnConnect_ = value;
    if (!value) {
        for (auto& [_, connection] : connections_) if (!connection.prompt.empty()) {
            connection.allowed = true;
            connection.prompt.clear();
        }
        refreshConnections();
    }
    publish();
    if (!value) poll();
}
void BackupCoordinator::respondToBackupPrompt(std::string_view id, bool backup) {
    refreshConnections();
    const auto found = std::find_if(connections_.begin(), connections_.end(), [&](const auto& entry) {
        return !id.empty() && entry.second.prompt == id;
    });
    if (found == connections_.end()) { publish(); return; }
    const auto disk = found->first;
    found->second.prompt.clear();
    found->second.allowed = backup;
    if (backup) {
        if (selected().presentation().job.volume != disk) selectDisk(disk);
        confirmedDisks_.insert(disk);
        if (!paused_) {
            refreshConnections();
            confirmedDisks_.erase(disk);
            if (connections_.contains(disk)) runDisk(disk, false, nullptr);
        }
    }
    publish();
}
void BackupCoordinator::setEjectAfterBackup(bool value) {
    const auto selectedJob = selected().presentation().job;
    for (auto job : all()) if (job->presentation().job.id == selectedJob.id ||
        (!selectedJob.set.empty() && job->presentation().job.set == selectedJob.set)) job->setEjectAfterBackup(value);
    publish();
}
void BackupCoordinator::setMedium(std::optional<StorageMedium> value, bool source) {
    const auto& volume = selected().presentation().volume;
    const auto device = source ? selected().presentation().sourceDevice :
        (volume ? std::make_optional(volume->device) : std::nullopt);
    if (!device || device->id.empty()) return;
    const auto key = folded(device->id);
    if (value) {
        media_[key] = *value;
        settings_->put("media", key, *value == StorageMedium::ssd ? "ssd" : "hdd");
    } else {
        media_.erase(key);
        settings_->remove("media", key);
    }
    for (auto job : all()) job->setMedia(media_);
    publish();
}
void BackupCoordinator::alignFolderName(SyncEngine& member) {
    const auto job = member.presentation().job;
    if (job.set.empty() || !stores_.contains(job.set) || member.presentation().progress.state == SyncState::takeoverRequired) return;
    const auto source = member.memberSource();
    auto set = sets_.at(job.set);
    auto& store = *stores_.at(job.set);
    auto map = std::find_if(set.mappings.begin(), set.mappings.end(), [&](const auto& entry) { return entry.job == job.id; });
    require(map != set.mappings.end(), "找不到此备份映射");
    const auto folder = join(parent(map->folder), utf8(source.filename()));
    if (folder != map->folder) {
        const auto base = set.revision;
        require(base < INT64_MAX, "备份集合的代次已满");
        const SetMove move{map->folder, folder, map->job};
        map->folder = folder;
        ++set.revision;
        member.bindMember({});
        try { store.apply({base, set, {}, {move}}); }
        catch (...) {
            if (const auto restored = store.recover()) attach(*restored, store);
            throw;
        }
        attach(set, store);
    }
    member.bindMember(store.volume, relativeToRoot(folder), source);
}
void BackupCoordinator::poll() {
    start();
    std::map<std::string, std::map<std::string, bool>> requests;
    for (auto job : all()) {
        job->observeSource();
        const auto& entry = job->presentation().job;
        const auto connection = connections_.find(entry.volume);
        if (!writable(entry) || connection == connections_.end() || !connection->second.allowed ||
            !job->presentation().volume || paused_) continue;
        if (const auto due = job->poll(false); due && !paused_)
            requests[entry.volume][entry.id] = *due;
    }
    for (const auto& [disk, due] : requests) if (!paused_) runDisk(disk, false, &due);
    publish();
}
SyncProgress BackupCoordinator::sync(bool verify) {
    start();
    const auto disk = selected().presentation().job.volume;
    if (!connections_.contains(disk)) refreshConnections();
    if (const auto connection = connections_.find(disk); connection != connections_.end()) {
        connection->second.allowed = true;
        connection->second.prompt.clear();
        refreshConnections();
    }
    return runDisk(disk, verify, nullptr);
}
SyncProgress BackupCoordinator::runDisk(std::string_view diskID, bool verify, const std::map<std::string, bool>* requests) {
    SyncProgress result;
    std::vector<SyncEngine*> jobs;
    bool allIncluded = true, autoEject = false, success = true;
    for (auto job : all()) {
        job->observeSource();
        const auto& entry = job->presentation().job;
        const auto map = mapping(entry);
        if (entry.id.empty() || entry.volume != diskID || entry.restoreOnly || (map && !map->enabled)) continue;
        if (requests && !entry.automatic) { allIncluded = false; continue; }
        jobs.push_back(job);
        autoEject |= entry.ejectAfterBackup;
    }
    if (jobs.empty()) return result;
    if (paused_) { result.state = SyncState::paused; return result; }
    const auto begin = Clock::now();
    busy_ = true;
    for (auto job : jobs) {
        if (paused_) break;
        active_ = job;
        const auto id = job->presentation().job.id;
        running_ = job->presentation().job.relative;
        publish();
        try {
            alignFolderName(*job);
            const auto item = job->sync(verify || (requests && requests->contains(id) && requests->at(id)));
            accumulate(result, item);
            success &= item.state == SyncState::upToDate;
            if (item.state != SyncState::upToDate) result.message = item.message;
        } catch (const std::exception& e) {
            job->report(e);
            result.message = e.what();
            ++result.issues;
            success = false;
        }
    }
    active_ = nullptr;
    running_.clear();
    result.state = paused_ ? SyncState::paused : (success ? SyncState::upToDate : SyncState::needsAttention);
    result.elapsedSeconds = std::chrono::duration<double>(Clock::now() - begin).count();
    diskProgress_[std::string(diskID)] = result;
    if (autoEject && allIncluded && success && !paused_) {
        try {
            if (std::none_of(jobs.begin(), jobs.end(), [](auto job) { return job->hasPendingChanges(); })) ejectDisk(diskID);
        } catch (const std::exception& e) { diskProgress_[std::string(diskID)].message = e.what(); }
    }
    busy_ = false;
    publish();
    return result;
}
void BackupCoordinator::requestPause() {
    paused_ = true;
    if (auto active = active_.load()) active->requestPause();
}
void BackupCoordinator::pause() {
    requestPause();
    for (auto job : all()) if (job->presentation().volume) job->pause();
    publish();
}
void BackupCoordinator::resume() {
    paused_ = false;
    for (auto job : all()) job->clearPause();
    if (!confirmedDisks_.empty()) {
        auto confirmed = std::exchange(confirmedDisks_, {});
        refreshConnections();
        for (const auto& disk : confirmed) if (connections_.contains(disk)) runDisk(disk, false, nullptr);
        publish();
        return;
    }
    const auto connection = connections_.find(selected().presentation().job.volume);
    if (connection != connections_.end() && connection->second.allowed) sync();
    publish();
}
void BackupCoordinator::safeEject() { ejectDisk(selected().presentation().job.volume); publish(); }
void BackupCoordinator::ejectDisk(std::string_view diskID) {
    std::optional<Volume> volume;
    std::vector<SyncEngine*> members;
    for (auto job : all()) if (job->presentation().job.volume == diskID) {
        if (job->presentation().volume) volume = job->presentation().volume;
        members.push_back(job);
    }
    if (!volume) {
        if (const auto connection = connections_.find(std::string(diskID)); connection != connections_.end())
            volume = connectedVolume(diskID, connection->second.mount);
    }
    require(volume.has_value(), "硬盘未连接");
    try {
        for (auto job : members) job->releaseForEjection();
        for (const auto& [id, binding] : bindings_) if (binding.volume == diskID) stores_.erase(id);
        eject(*volume);
        ejected_[std::string(diskID)] = volume->mount;
        connections_.erase(std::string(diskID));
        confirmedDisks_.erase(std::string(diskID));
    } catch (...) {
        for (auto job : members) job->allowReconnect();
        refreshConnections();
        throw;
    }
    paused_ = false;
}
}
