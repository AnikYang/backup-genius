#include "Engine.h"

#include <algorithm>
#include <future>
#include <set>
#include <stdexcept>

namespace bg {
namespace {
using Clock = std::chrono::steady_clock;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
struct Paused : std::runtime_error { Paused() : std::runtime_error("备份已暂停") {} };
struct Work {
    std::string path;
    std::optional<Stamp> source;
    Json old, observed;
    uint32_t flags{};
    bool checkTarget{};
    std::string from;
};
struct Prepared {
    Json edit, original;
    std::optional<Stamp> before;
    Bytes oldHashes;
    Patch patch;
    int64_t read{}, targetRead{}, written{}, patchBytes{};
    bool archive{}, retry{};
    std::string issue;
};
Json lookup(const Records& records, const std::string& rel) {
    const auto found = records.find(rel);
    return found != records.end() ? found->second : Json(nullptr);
}
bool directory(const Json& record) { return !record.is_null() && record.at("source").at("kind") == "directory"; }
bool link(const Json& record) { return !record.is_null() && record.at("source").at("kind") == "symlink"; }
bool safeEntry(const std::string& rel, const Json& record) { return representable(rel) && !link(record); }
int depth(std::string_view path) { return static_cast<int>(std::count(path.begin(), path.end(), '/')); }
bool stable(const Json& observation, const Stamp& stamp) {
    if (observation.is_null()) return false;
    if (stamp.kind == Kind::directory) return observation.value("kind", "") == "directory" &&
        observation.value("id", "") == stamp.identity && observation.value("attributes", uint32_t{}) == stamp.attributes;
    return observation == observedStamp(stamp);
}
bool exactName(const Tree& tree, const std::string& rel) {
    if (!tree.entry(parent(rel))) return false;
    auto names = tree.children(parent(rel));
    return std::find(names.begin(), names.end(), name(rel)) != names.end();
}
void setMeta(const Tree& tree, std::string_view rel, const Json& attrs) {
    tree.metadata(rel, decodeTime(attrs.at("modified")), decodeTime(attrs.at("birth")), attrs.value("windows", uint32_t{}));
}
Json jobJSON(const BackupJob& job) {
    return {{"id", job.id}, {"volume", job.volume}, {"format", job.format}, {"relative", job.relative},
        {"sourceId", job.sourceId}, {"source", utf8(job.source)}, {"target", utf8(job.target)},
        {"automatic", job.automatic}, {"restoreOnly", job.restoreOnly}};
}
BackupJob loadJob(const Json& j) {
    return {identifier(j.at("id")), j.at("volume"), j.at("format"), j.at("relative"), j.at("sourceId"),
        path(j.at("source").get<std::string>()), path(j.at("target").get<std::string>()), j.at("automatic"), j.at("restoreOnly")};
}
void validateFolders(const fs::path& source, const fs::path& target, const fs::path& storage) {
    const auto a = folded(utf8(source)), b = folded(utf8(target)), c = folded(utf8(storage));
    require(!inside(a, b) && !inside(b, a) && !inside(a, c) && !inside(c, a) && !inside(b, c) && !inside(c, b),
            "源文件夹、目标文件夹和应用数据不得重叠");
}
Json snapshotFile(const Tree& tree, const std::string& rel, const Stamp& stamp, const Json& old = nullptr) {
    require(stamp.kind != Kind::unsupported && validPath(rel), "不支持的文件类型或保留名称");
    Bytes hashes;
    if (stamp.kind == Kind::regular) hashes = hashFile(tree.file(rel), stamp.size);
    auto record = recipe(rel, stamp, hashes, old);
    if (stamp.kind == Kind::link) {
        record["link"] = base64(utf8(fs::read_symlink(tree.checked(rel))));
        record["attributes"]["windowsLink"] = true;
        record["attributes"]["windowsLinkDirectory"] = (stamp.attributes & 0x10) != 0;
    }
    require(tree.entry(rel) == stamp, "文件正在写入");
    return record;
}
Records sourceSnapshot(const Tree& source) {
    Records result;
    source.walk({}, [&](const std::string& rel, const Stamp& stamp) { result[rel] = snapshotFile(source, rel, stamp); }, false);
    source.check();
    return result;
}
bool equalSnapshots(const Records& a, const Records& b) {
    if (a.size() != b.size()) return false;
    for (const auto& [rel, record] : a) if (!sameContent(record, lookup(b, rel))) return false;
    return true;
}
Json oldRecord(const Tree& tree, const Work& work, const Stamp& actual, std::string_view hashes) {
    auto original = recipe(work.path, actual, hashes, work.old);
    if (!work.old.is_null() && work.old.at("hashes") == original.at("hashes")) {
        auto saved = work.old.at("attributes");
        auto latest = original.at("attributes");
        saved["windows"] = latest.at("windows");
        original["attributes"] = saved;
    }
    (void)tree;
    return original;
}
Json makeEdit(std::string method, std::string rel, const std::optional<Stamp>& before, Json next = nullptr) {
    Json edit = {{"method", std::move(method)}, {"path", std::move(rel)}, {"rollbackBlocks", Json::array()}};
    if (before) edit["before"] = portableStamp(*before);
    if (!next.is_null()) edit["next"] = std::move(next);
    return edit;
}

Prepared prepare(const Work& work, const Tree& source, const Tree& target, const Tree& scratch) {
    Prepared result;
    const auto& rel = work.path;
    if (!validPath(rel) || !representable(rel) || (work.source && work.source->kind == Kind::unsupported)) {
        result.issue = "名称或文件类型在此平台无法表示";
        return result;
    }
    const auto actual = target.entry(work.from.empty() ? rel : work.from);
    result.before = actual;
    const auto observeSource = work.observed.value("source", Json(nullptr));
    const auto observeTarget = work.observed.value("target", Json(nullptr));
    if (!work.from.empty()) {
        require(work.source && !work.old.is_null() && actual && stable(observeTarget, *actual), "移动前目标文件已变化");
        auto next = work.old;
        next["path"] = rel;
        next["source"] = portableStamp(*work.source);
        result.edit = makeEdit(folded(rel) == folded(work.from) ? "caseMove" : "move", rel, actual, next);
        result.edit["from"] = work.from;
        result.edit["staging"] = uuid();
        result.edit["activity"] = activity("moved", rel, 0, work.from);
        return result;
    }
    if (!work.source) {
        if (!work.old.is_null() && work.old.value("sharedDirectory", false)) {
            result.edit = makeEdit("record", rel, {});
            return result;
        }
        if (link(work.old)) {
            if (work.old.at("attributes").value("windowsLink", false) && observeSource.is_object() &&
                observeSource.value("kind", "") == "symlink" && !actual) {
                result.edit = makeEdit("record", rel, {});
                result.edit["archive"] = archiveVersion(work.old, "deleted");
                result.edit["activity"] = activity("deleted", rel);
            } else result.issue = "保留未在本机表示的链接";
            return result;
        }
        if (work.old.is_null()) return result;
        if (actual && (kindName(actual->kind) != work.old.at("source").at("kind").get<std::string>())) {
            result.issue = "目标的文件类型已更改";
            return result;
        }
        result.edit = makeEdit(actual ? "remove" : "record", rel, actual);
        result.archive = actual.has_value();
        result.original = work.old;
        result.oldHashes = actual && !work.checkTarget && stable(observeTarget, *actual)
            ? unbase64(work.old.at("hashes").get<std::string>()) : Bytes{};
        result.edit["activity"] = activity("deleted", rel);
        return result;
    }
    const auto stamp = *work.source;
    if (actual && (work.old.is_null() || link(work.old))) {
        result.issue = "目标位置已有未管理文件";
        return result;
    }
    if (actual && actual->kind != stamp.kind) {
        result.issue = "请先处理目标文件类型冲突";
        return result;
    }
    if (link(work.old) && stamp.kind != Kind::link) {
        result.issue = "目标有需要保留的链接记录";
        return result;
    }
    if (stamp.kind == Kind::link) {
        auto next = snapshotFile(source, rel, stamp, work.old);
        if (!work.old.is_null() && sameContent(next, work.old) && next.at("attributes") == work.old.at("attributes")) return result;
        result.edit = makeEdit("record", rel, {}, next);
        if (!work.old.is_null()) result.edit["archive"] = archiveVersion(work.old, "updated");
        result.edit["activity"] = activity(work.old.is_null() ? "added" : "updated", rel, 0, "链接信息已保存");
        return result;
    }
    if (stamp.kind == Kind::directory) {
        auto next = recipe(rel, stamp, {}, work.old);
        if (actual && !work.old.is_null() && work.old.value("sharedDirectory", false)) next["sharedDirectory"] = true;
        if (actual && stable(observeSource, stamp) && stable(observeTarget, *actual)) return result;
        if (!actual) {
            const auto stage = uuid();
            auto location = join(stagePath, stage);
            target.mkdir(location);
            setMeta(target, location, next.at("attributes"));
            result.edit = makeEdit("install", rel, {}, next);
            result.edit["staging"] = stage;
        } else {
            next["target"] = portableStamp(*actual);
            result.edit = makeEdit("record", rel, actual, next);
        }
        result.edit["activity"] = activity(work.old.is_null() ? "added" : "updated", rel);
        return result;
    }

    auto input = source.file(rel);
    require(input.stamp() == stamp, "读取前源文件已变化");
    Bytes targetHashes;
    if (actual) {
        targetHashes = work.checkTarget || !stable(observeTarget, *actual) ?
            hashFile(target.file(rel), actual->size, &result.targetRead) : unbase64(work.old.at("hashes").get<std::string>());
        require(target.entry(rel) == actual, "读取时目标文件已变化");
    }
    const bool sourceTrusted = !work.old.is_null() && !(work.flags & contentChange) && stable(observeSource, stamp);
    const auto cachedHashes = sourceTrusted ? unbase64(work.old.at("hashes").get<std::string>()) : Bytes{};
    Bytes hashes;
    std::optional<File> output;
    const auto stage = uuid();
    const auto location = join(stagePath, stage);
    const auto spool = scratch.checked(stage);
    auto rollbackBlocks = Json::array();
    try {
        if (!actual) output.emplace(target.file(location, File::Mode::create));
        for (int64_t offset = 0; offset < stamp.size;) {
            const auto length = static_cast<size_t>(std::min(blockSize, stamp.size - offset));
            const auto i = static_cast<size_t>(offset / blockSize * 32);
            Bytes data;
            Bytes hash;
            if (sourceTrusted) hash = cachedHashes.substr(i, 32);
            else {
                data = input.read(offset, length);
                result.read += static_cast<int64_t>(data.size());
                hash = sha256(data);
            }
            hashes += hash;
            if (!actual || i >= targetHashes.size() || hash != std::string_view(targetHashes).substr(i, 32)) {
                if (data.empty()) {
                    data = input.read(offset, length);
                    result.read += static_cast<int64_t>(data.size());
                    require(sha256(data) == hash, "源文件内容已变化");
                }
                if (!actual) {
                    output->write(offset, data);
                    result.written += static_cast<int64_t>(length);
                } else {
                    if (!output) output.emplace(spool, File::Mode::create);
                    output->write(result.patchBytes, data);
                    result.patchBytes += static_cast<int64_t>(length);
                    result.patch.blocks.push_back(offset / blockSize);
                    if (offset < actual->size) rollbackBlocks.push_back(offset / blockSize);
                }
            }
            offset += static_cast<int64_t>(length);
        }
        require(input.stamp() == stamp && source.entry(rel) == stamp, "等待文件稳定");
        auto next = recipe(rel, stamp, hashes, work.old);
        if (!actual) {
            output->flush();
            output.reset();
            setMeta(target, location, next.at("attributes"));
            result.edit = makeEdit("install", rel, {}, next);
            result.edit["staging"] = stage;
            result.edit["activity"] = activity(work.old.is_null() ? "added" : "updated", rel, result.written);
            return result;
        }
        next["target"] = portableStamp(*actual);
        auto original = oldRecord(target, work, *actual, targetHashes);
        const bool bytesDiffer = result.patchBytes != 0 || actual->size != stamp.size;
        const auto expectedTarget = work.old.value("target", Json(nullptr));
        const bool metadataChanged = work.old.at("attributes") != next.at("attributes") ||
            (work.checkTarget && expectedTarget.is_object() &&
             decodeTime(expectedTarget.at("modified")) != actual->modified);
        if (bytesDiffer) {
            output.reset();
            if (result.patchBytes) result.patch.spool = spool;
            result.edit = makeEdit("patch", rel, actual, next);
            result.edit["rollbackBlocks"] = std::move(rollbackBlocks);
        } else if (metadataChanged) {
            result.edit = makeEdit("attributes", rel, actual, next);
            result.edit["originalAttributes"] = attributes(*actual);
        } else {
            return result;
        }
        result.oldHashes = std::move(targetHashes);
        result.original = std::move(original);
        result.archive = bytesDiffer || metadataChanged;
        result.edit["activity"] = activity("updated", rel, result.patchBytes);
        return result;
    } catch (...) {
        output.reset();
        try { scratch.remove(stage); } catch (...) {}
        try { if (!actual) target.remove(location); } catch (...) {}
        throw;
    }
}
}

struct SyncEngine::Draft {
    fs::path source;
    std::string identity;
    TakeoverPreview preview;
    Records local, disk;
};

SyncEngine::SyncEngine(fs::path storage, Progress update, bool allowInternal, Fault fault)
    : storage_(std::move(storage)), notify_(std::move(update)), fault_(std::move(fault)), allowInternal_(allowInternal) {}
SyncEngine::~SyncEngine() = default;
void SyncEngine::publish(bool force) {
    auto time = Clock::now();
    if (force || time - published_ >= std::chrono::milliseconds(200)) {
        published_ = time;
        if (notify_) notify_(view_);
    }
}
void SyncEngine::start() {
    if (settings_) return;
    fs::create_directories(storage_ / "scratch");
    storage_ = fs::canonical(storage_);
    settings_ = std::make_unique<Index>(storage_ / "settings.sqlite");
    auto savedHost = settings_->get("settings", "host");
    host_ = savedHost.is_null() ? uuid() : identifier(savedHost);
    settings_->put("settings", "host", host_);
    const auto job = settings_->get("settings", "job");
    if (!job.is_null()) {
        setJob(loadJob(job));
        try { refresh(); } catch (const std::exception& error) { fail(error); }
    }
    publish(true);
}
void SyncEngine::setJob(BackupJob job) {
    targetWatch_.reset();
    sourceWatch_.reset();
    repo_.reset();
    draft_.reset();
    view_.job = std::move(job);
    view_.volume.reset();
    view_.progress = {};
    index_ = std::make_unique<Index>(storage_ / (view_.job.id + ".sqlite"));
    paused_ = false;
    suppress_ = false;
    sourceGap_ = true;
    verifyAttempted_ = false;
}
void SyncEngine::saveJob() { settings_->put("settings", "job", jobJSON(view_.job)); }
void SyncEngine::configure(const fs::path& in, const fs::path& out, bool automatic) {
    start();
    Tree source(in), target(out);
    validateFolders(source.root(), target.root(), storage_);
    const auto volume = inspect(target.root());
    require(volume.external || allowInternal_, "请选择外置硬盘上的目标文件夹");
    auto format = volume.format;
#ifndef _WIN32
    if (allowInternal_ && format != "exfat") format = "exfat";
#endif
    auto marker = Repository::create(target, format, host_);
    auto relative = target.root().lexically_relative(volume.mount);
    setJob({identifier(marker.at("job")), volume.id, format, relative == "." ? "" : utf8(relative),
        source.identity().identity, source.root(), target.root(), automatic, false});
    saveJob();
    refresh();
    publish(true);
}
void SyncEngine::openExisting(const fs::path& out) {
    start();
    Tree target(out);
    const auto volume = inspect(target.root());
    require(volume.external || allowInternal_, "请选择外置备份硬盘");
    auto marker = Repository::readMarker(target);
    auto relative = target.root().lexically_relative(volume.mount);
    setJob({identifier(marker.at("job")), volume.id, marker.at("format"), relative == "." ? "" : utf8(relative), "",
        {}, target.root(), false, true});
    saveJob();
    refresh();
    publish(true);
}
Tree SyncEngine::sourceTree() const {
    require(!view_.job.source.empty(), "请选择源文件夹");
    Tree tree(view_.job.source);
    require(tree.identity().identity == view_.job.sourceId, "源文件夹已替换，请重新选择");
    return tree;
}
bool SyncEngine::requiresTakeover() {
    return repo_ && !view_.job.restoreOnly && (repo_->marker.at("version") != 2 || repo_->owner != host_ ||
        index_->get("meta", "binding") != view_.job.sourceId || !index_->get("meta", "alignment").is_null());
}
void SyncEngine::refresh() {
    if (view_.job.id.empty()) return;
    if (!view_.job.restoreOnly && !sourceWatch_) {
        try { sourceWatch_ = std::make_unique<DirectoryWatch>(sourceTree().root()); } catch (...) {}
    }
    if (repo_) {
        try { repo_->tree.check(); } catch (...) {
            repo_.reset();
            targetWatch_.reset();
            view_.volume.reset();
        }
        if (repo_) {
            if (repo_->tree.entry(pendingPath)) {
                view_.progress.state = SyncState::recovering;
                publish(true);
                repo_->open();
                recordChanges({{}, true}, true);
            }
            return;
        }
    }
    if (suppress_) {
        if (findVolume(view_.job.volume)) return;
        suppress_ = false;
    }
    fs::path target = view_.job.target;
    auto attached = [&] {
        try { return inspect(target).id == view_.job.volume && fs::is_directory(target); }
        catch (...) { return false; }
    };
    if (!attached()) {
        const auto mount = findVolume(view_.job.volume);
        if (mount) target = view_.job.relative.empty() ? *mount : *mount / path(view_.job.relative);
    }
    if (!attached()) {
        view_.progress.state = SyncState::disconnected;
        view_.progress.message.clear();
        return;
    }
    Tree tree(target);
    auto volume = inspect(target);
    require(allowInternal_ || (volume.external && volume.format == view_.job.format), "目标卷与登记的硬盘不符");
    require(identifier(Repository::readMarker(tree).at("job")) == view_.job.id, "备份位置属于另一任务");
    auto repo = std::make_unique<Repository>(std::move(tree), *index_, host_, fault_);
    if (repo->tree.entry(pendingPath)) {
        view_.progress.state = SyncState::recovering;
        publish(true);
    }
    repo->open();
    if (repo->owner == host_ && repo->generation == 0 && !view_.job.restoreOnly && index_->get("meta", "binding").is_null())
        repo->bind(view_.job.sourceId);
    if (repo->recovered) index_->put("activity", uuid(), activity("recovered", "", 0, "已回滚未完成的事务"));
    view_.job.target = target;
    view_.volume = volume;
    targetWatch_ = std::make_unique<DirectoryWatch>(target);
    repo_ = std::move(repo);
    recordChanges({{}, true}, true);
    view_.progress.tracked = index_->count("file");
    view_.progress.state = requiresTakeover() ? SyncState::takeoverRequired : (paused_ ? SyncState::paused : SyncState::ready);
    view_.progress.message.clear();
}
void SyncEngine::recordChanges(const Changes& changes, bool target) {
    if (!index_ || (changes.paths.empty() && !changes.full)) return;
    const auto bucket = target ? "targetDirty" : "sourceDirty";
    index_->transaction([&] {
        if (changes.full) index_->put("meta", target ? "targetFull" : "sourceFull", true);
        for (const auto& [rel, flags] : changes.paths) {
            if (!validPath(rel)) continue;
            auto old = index_->get(bucket, rel);
            index_->put(bucket, rel, flags | (old.is_null() ? 0u : old.get<uint32_t>()));
            if (!target) index_->remove("retry", rel);
        }
    });
}
void SyncEngine::drain() {
    if (sourceWatch_) recordChanges(sourceWatch_->take());
    if (targetWatch_) recordChanges(targetWatch_->take(), true);
}
void SyncEngine::setAutomatic(bool value) {
    view_.job.automatic = value;
    if (!view_.job.id.empty()) saveJob();
    publish(true);
}
void SyncEngine::poll() {
    start();
    const auto previous = view_.progress.state;
    try {
        refresh();
        drain();
        if (repo_ && !view_.job.restoreOnly && !paused_ && !requiresTakeover()) {
            auto time = Clock::now();
            if (time - lastMaintenance_ > std::chrono::minutes(1)) {
                lastMaintenance_ = time;
                const auto previousPrune = index_->get("meta", "lastPrune");
                if (!previousPrune.is_null() && now().seconds - integer(previousPrune) >= 86400) {
                    repo_->prune(now());
                    index_->put("meta", "lastPrune", now().seconds);
                }
            }
            if ((!sourceWatch_ || !sourceWatch_->alive()) && time - lastPollScan_ > std::chrono::minutes(1)) {
                recordChanges({{}, true});
                lastPollScan_ = time;
            }
            const auto last = index_->get("meta", "lastVerify");
            const bool verify = !last.is_null() && now().seconds - integer(last) >= 7 * 86400 && !verifyAttempted_;
            if (view_.job.automatic && time - lastAttempt_ >= std::chrono::milliseconds(900) &&
                (sourceGap_ || verify || index_->count("sourceDirty") || index_->count("targetDirty") ||
                 index_->get("meta", "sourceFull") == true || index_->get("meta", "targetFull") == true)) {
                lastAttempt_ = time;
                verifyAttempted_ = verify;
                sync(verify);
            }
        }
        if (previous != view_.progress.state) publish(true);
    } catch (const std::exception& error) { fail(error); }
}
void SyncEngine::requestPause() { paused_ = true; }
void SyncEngine::pause() {
    requestPause();
    refresh();
    if (repo_) view_.progress.state = requiresTakeover() ? SyncState::takeoverRequired : SyncState::paused;
    publish(true);
}
void SyncEngine::resume() {
    paused_ = false;
    suppress_ = false;
    sync();
}
void SyncEngine::safeEject() {
    requestPause();
    refresh();
    require(view_.volume.has_value(), "硬盘未连接");
    auto volume = *view_.volume;
    repo_->tree.flushDirectory();
    if (!view_.job.source.empty()) {
        try {
            if (inspect(view_.job.source).id == volume.id) {
                sourceWatch_.reset();
                sourceGap_ = true;
            }
        } catch (...) {}
    }
    targetWatch_.reset();
    repo_.reset();
    view_.volume.reset();
    try { eject(volume); }
    catch (...) { paused_ = false; throw; }
    suppress_ = true;
    paused_ = false;
    view_.progress.state = SyncState::disconnected;
    publish(true);
}
void SyncEngine::fail(const std::exception& error) {
    view_.progress.state = SyncState::needsAttention;
    view_.progress.message = error.what();
    if (repo_) {
        try { repo_->tree.check(); } catch (...) {
            repo_.reset();
            targetWatch_.reset();
            view_.volume.reset();
            view_.progress.state = SyncState::disconnected;
        }
    }
    publish(true);
}
SyncProgress SyncEngine::sync(bool verify) {
    try { return run(verify); }
    catch (const Paused&) {
        view_.progress.state = SyncState::paused;
        publish(true);
        return view_.progress;
    } catch (const std::exception& error) {
        fail(error);
        throw;
    }
}

SyncProgress SyncEngine::run(bool verify) {
    if (paused_) throw Paused();
    start();
    refresh();
    if (!repo_) { publish(true); return view_.progress; }
    if (requiresTakeover()) { view_.progress.state = SyncState::takeoverRequired; publish(true); return view_.progress; }
    require(!view_.job.restoreOnly, "请先设置备份任务");
    const auto source = sourceTree();
    const auto scratch = Tree(storage_ / "scratch");
    const auto begun = Clock::now();
    auto& p = view_.progress;
    const auto priorUnmanaged = p.unmanaged;
    p = {};
    p.unmanaged = priorUnmanaged;
    p.state = verify ? SyncState::verifying : SyncState::checking;
    publish(true);
    drain();
    auto cursor = currentCursor(source.root());
    if (sourceGap_) {
        auto saved = index_->get("meta", "usn");
        std::optional<Changes> changes;
        if (cursor && saved.is_object()) {
            Cursor old{saved.at("journal").get<uint64_t>(), integer(saved.at("next"))};
            changes = changesSince(source.root(), old, *cursor);
        }
        recordChanges(changes.value_or(Changes{{}, true}));
        sourceGap_ = false;
    }
    const auto sourceDirty = index_->all("sourceDirty"), targetDirty = index_->all("targetDirty");
    const auto fullSource = verify || index_->get("meta", "sourceFull") == true;
    const auto fullTarget = verify || index_->get("meta", "targetFull") == true;
    std::map<std::string, Work> candidates;
    std::set<std::string> blocked;
    auto add = [&](const std::string& rel, const std::optional<Stamp>& stamp, uint32_t flags, bool targetEvidence) {
        if (paused_) throw Paused();
        auto [it, inserted] = candidates.try_emplace(rel);
        auto& item = it->second;
        if (inserted) {
            item.path = rel;
            item.old = index_->get("file", rel);
            item.observed = index_->get("observed", rel);
            if (!item.observed.is_object()) item.observed = Json::object();
            ++p.examined;
            publish();
        }
        item.source = stamp;
        item.flags |= flags;
        item.checkTarget |= targetEvidence;
    };
    const auto probeSource = [&](const std::string& rel) -> std::optional<Stamp> {
        if (!representable(rel)) return Stamp{.kind = Kind::unsupported};
        return source.entry(rel);
    };
    if (fullSource) {
        std::set<std::string> seen;
        source.walk({}, [&](const std::string& rel, const Stamp& stamp) {
            if (paused_) throw Paused();
            seen.insert(rel);
            const auto observation = index_->get("observed", rel);
            if (verify || !observation.is_object() || !stable(observation.value("source", Json(nullptr)), stamp))
                add(rel, stamp, verify ? contentChange : 0, verify);
        }, false);
        for (const auto& [rel, record] : index_->all("file")) {
            if (!seen.contains(rel)) add(rel, {}, 0, verify);
        }
    }
    for (const auto& [rel, rawFlags] : sourceDirty) {
        const auto flags = rawFlags.get<uint32_t>();
        auto stamp = probeSource(rel);
        if (stamp && (flags & nameChange) && !exactName(source, rel)) stamp.reset();
        add(rel, stamp, flags, verify);
        if (!stamp) {
            for (const auto& [child, _] : index_->below("file", rel)) if (child != rel) add(child, probeSource(child), flags, verify);
        } else if (stamp->kind == Kind::directory && (flags & nameChange)) {
            source.walk(rel, [&](const std::string& child, const Stamp& item) { add(child, item, flags, verify); });
        }
    }
    if (fullTarget) {
        std::set<std::string> seen;
        p.unmanaged = 0;
        repo_->tree.walk({}, [&](const std::string& rel, const Stamp& stamp) {
            if (paused_) throw Paused();
            seen.insert(rel);
            if (index_->get("file", rel).is_null()) ++p.unmanaged;
            else {
                const auto observation = index_->get("observed", rel);
                if (verify || !observation.is_object() || !stable(observation.value("target", Json(nullptr)), stamp))
                    add(rel, probeSource(rel), verify ? contentChange : 0, true);
            }
        });
        for (const auto& [rel, record] : index_->all("file")) {
            if (!seen.contains(rel) && !link(record)) add(rel, probeSource(rel), 0, true);
            if (!safeEntry(rel, record) && (link(record) && !probeSource(rel))) add(rel, {}, 0, false);
        }
    }
    for (const auto& [rel, flags] : targetDirty) {
        if (!representable(rel)) continue;
        const auto record = index_->get("file", rel);
        if (record.is_null()) {
            if ((flags.get<uint32_t>() & nameChange) && repo_->tree.entry(rel)) {
                auto present = index_->get("unmanaged", rel);
                if (present.is_null() && !fullTarget) ++p.unmanaged;
                index_->put("unmanaged", rel, true);
            } else if (!index_->get("unmanaged", rel).is_null()) {
                p.unmanaged = std::max<int64_t>(0, p.unmanaged - 1);
                index_->remove("unmanaged", rel);
            }
            continue;
        }
        const auto actual = repo_->tree.entry(rel);
        auto observed = index_->get("observed", rel);
        if (!actual || !observed.is_object() || !stable(observed.value("target", Json(nullptr)), *actual) ||
            (actual->kind == Kind::regular && (flags.get<uint32_t>() & contentChange)))
            add(rel, probeSource(rel), 0, true);
        if (!actual || actual->kind == Kind::directory) {
            if ((flags.get<uint32_t>() & nameChange) && (!actual || !stable(observed.value("target", Json(nullptr)), *actual))) {
                for (const auto& [child, _] : index_->below("file", rel))
                    if (child != rel) add(child, probeSource(child), 0, true);
            }
        }
    }
    source.check();
    repo_->tree.check();
    std::map<std::string, std::vector<std::string>> missingIDs;
    for (const auto& [rel, item] : candidates) {
        auto before = item.observed.value("source", Json(nullptr));
        if (!item.source && !item.old.is_null() && !directory(item.old) && !link(item.old) && before.is_object() &&
            !item.checkTarget && !verify) {
            auto id = before.value("id", "");
            if (!id.empty()) missingIDs[id].push_back(rel);
        }
    }
    std::set<std::string> moved;
    for (auto& [rel, item] : candidates) {
        if (!item.source || item.source->kind != Kind::regular || !item.old.is_null() ||
            item.checkTarget || verify || !representable(rel)) continue;
        auto ids = missingIDs.find(item.source->identity);
        if (ids == missingIDs.end() || ids->second.size() != 1 || moved.contains(ids->second.front())) continue;
        auto& previous = candidates.at(ids->second.front());
        auto stamp = previous.observed.at("source");
        const auto before = repo_->tree.entry(previous.path), after = repo_->tree.entry(rel);
        if (!before || !stable(previous.observed.value("target", Json(nullptr)), *before) ||
            (after && folded(previous.path) != folded(rel)) || integer(stamp.at("size")) != item.source->size ||
            decodeTime(stamp.at("modified")) != item.source->modified || stamp.at("attributes") != item.source->attributes) continue;
        if (item.flags & contentChange) {
            auto input = source.file(rel);
            if (base64(hashFile(input, item.source->size, &p.sourceRead)) != previous.old.at("hashes").get<std::string>() ||
                input.stamp() != *item.source || source.entry(rel) != item.source) continue;
        }
        item.from = previous.path;
        item.old = previous.old;
        item.observed = previous.observed;
        moved.insert(previous.path);
    }
    for (const auto& rel : moved) candidates.erase(rel);
    std::map<std::string, std::string> names;
    for (const auto& [rel, item] : candidates) {
        if (!validPath(rel) || !representable(rel) || (item.source && item.source->kind == Kind::unsupported)) {
            blocked.insert(rel);
            continue;
        }
        if (!item.source) continue;
        const auto key = folded(rel);
        auto old = index_->get("folded", key);
        if (!old.is_null() && old != rel && old != item.from) {
            blocked.insert(rel);
            blocked.insert(old.get<std::string>());
        }
        auto [it, inserted] = names.emplace(key, rel);
        if (!inserted && it->second != rel) { blocked.insert(rel); blocked.insert(it->second); }
    }
    for (const auto& [rel, item] : candidates) {
        auto priorSource = item.observed.value("source", Json(nullptr));
        const bool foreignLink = !item.source && link(item.old) && (!item.old.at("attributes").value("windowsLink", false) ||
            !priorSource.is_object() || priorSource.value("kind", "") != "symlink");
        if (foreignLink || (!item.old.is_null() && !representable(rel))) {
            blocked.insert(rel);
            for (auto dir = parent(rel); !dir.empty(); dir = parent(dir)) {
                auto found = candidates.find(dir);
                if (found != candidates.end() && !found->second.source) blocked.insert(dir);
            }
        }
    }
    auto blockedPath = [&](const std::string& rel) {
        for (auto path = rel; !path.empty(); path = parent(path)) if (blocked.contains(path)) return true;
        return false;
    };
    std::map<int, std::vector<Work>> waves;
    for (auto& [rel, work] : candidates) {
        if (blockedPath(rel)) {
            index_->put("issue", rel, activity("issue", rel, 0, "文件名、链接或类型冲突，已保留备份"));
            continue;
        }
        const auto wave = !work.source ? 200000 - depth(rel) : (work.source->kind == Kind::directory ? depth(rel) : 100000);
        waves[wave].push_back(std::move(work));
        ++p.planned;
    }
    p.checkingSeconds = std::chrono::duration<double>(Clock::now() - begun).count();
    if (p.planned) { p.state = SyncState::syncing; publish(true); }
    std::map<std::string, int> retry;
    for (const auto& [_, items] : waves) {
        for (size_t offset = 0; offset < items.size(); offset += 128) {
            if (paused_) throw Paused();
            const auto count = std::min<size_t>(128, items.size() - offset);
            std::vector<Prepared> results(count);
            const auto workers = std::min<size_t>(view_.volume->solidState ? 4 : 1, count);
            auto workStripe = [&](size_t worker) {
                for (size_t i = worker; i < count; i += workers) {
                    try { results[i] = prepare(items[offset + i], source, repo_->tree, scratch); }
                    catch (const std::system_error& e) {
                        results[i].issue = e.what();
                        results[i].retry = e.code().value() == 32 || e.code().value() == 33;
                    } catch (const std::exception& e) {
                        results[i].issue = e.what();
                        results[i].retry = results[i].issue.find("变化") != std::string::npos ||
                            results[i].issue.find("稳定") != std::string::npos;
                    }
                }
            };
            std::vector<std::future<void>> threads;
            for (size_t i = 1; i < workers; ++i) threads.push_back(std::async(std::launch::async, workStripe, i));
            workStripe(0);
            for (auto& thread : threads) thread.get();
            auto batch = repo_->batch();
            PackWriter writer(*repo_, identifier(batch.at("id")));
            std::unordered_map<std::string, Patch> patches;
            std::unordered_map<std::string, std::optional<Stamp>> expected;
            std::vector<size_t> ready;
            struct Cleanup {
                const Tree& scratch;
                std::vector<Prepared>& results;
                ~Cleanup() {
                    for (const auto& item : results) if (!item.patch.spool.empty()) {
                        try { scratch.remove(utf8(item.patch.spool.filename())); } catch (...) {}
                    }
                }
            } cleanup{scratch, results};
            for (size_t i = 0; i < count; ++i) {
                auto& result = results[i];
                const auto& item = items[offset + i];
                p.sourceRead += result.read;
                p.targetRead += result.targetRead;
                p.latestWritten += result.written;
                if (!result.issue.empty()) {
                    index_->put("issue", item.path, activity("issue", item.path, 0, result.issue));
                    const auto prior = index_->get("retry", item.path);
                    const auto attempts = prior.is_null() ? 0 : prior.get<int>();
                    if (result.retry && attempts < 2) retry[item.path] = attempts + 1;
                    continue;
                }
                if (!result.edit.is_null()) {
                    if (result.archive && result.before) {
                        auto original = result.original;
                        if (result.before->kind == Kind::regular) {
                            auto hashes = writer.saveFile(repo_->tree, item.path, *result.before, result.oldHashes, p.targetRead);
                            original = oldRecord(repo_->tree, item, *result.before, unbase64(hashes.get<std::string>()));
                        } else if (original.is_null()) original = recipe(item.path, *result.before, {});
                        result.edit["archive"] = archiveVersion(original, item.source ? "updated" : "deleted");
                    }
                    if (result.edit.at("method") == "patch") patches.emplace(item.path, result.patch);
                    expected[item.path] = result.before;
                    batch["edits"].push_back(result.edit);
                }
                ready.push_back(i);
            }
            if (!batch["edits"].empty()) {
                batch["chunks"] = writer.finish();
                p.historyWritten += writer.bytes();
                repo_->commit(batch, patches, [&] {
                    source.check();
                    for (auto i : ready) {
                        const auto& item = items[offset + i];
                        auto current = source.entry(item.path);
                        require(current == item.source || (current && item.source && current->kind == Kind::directory &&
                            current->identity == item.source->identity), "提交前源文件已变化");
                        if (!item.from.empty() && folded(item.from) != folded(item.path))
                            require(!source.entry(item.from), "移动前源路径重新出现");
                    }
                }, true, expected);
            }
            index_->transaction([&] {
                for (auto i : ready) {
                    const auto& item = items[offset + i];
                    const auto& result = results[i];
                    p.latestWritten += result.patchBytes;
                    index_->remove("issue", item.path);
                    index_->remove("retry", item.path);
                    if (item.source) {
                        Json observed = {{"source", observedStamp(*item.source)}};
                        if (auto actual = repo_->tree.entry(item.path)) observed["target"] = observedStamp(*actual);
                        index_->put("observed", item.path, observed);
                    }
                    if (result.edit.is_null()) ++p.skipped;
                }
            });
            p.currentPath = items[offset + count - 1].path;
            p.processed += static_cast<int64_t>(count);
            publish();
        }
    }
    source.check();
    repo_->tree.check();
    auto issues = index_->count("issue");
    index_->transaction([&] {
        index_->clear("sourceDirty");
        index_->clear("targetDirty");
        for (const auto& [rel, attempts] : retry) {
            index_->put("sourceDirty", rel, contentChange);
            index_->put("retry", rel, attempts);
        }
        index_->put("meta", "sourceFull", false);
        index_->put("meta", "targetFull", false);
        if (cursor) index_->put("meta", "usn", Json{{"journal", cursor->journal}, {"next", cursor->next}});
        if (issues == 0 && (verify || index_->get("meta", "lastVerify").is_null())) index_->put("meta", "lastVerify", now().seconds);
    });
    const auto previousPrune = index_->get("meta", "lastPrune");
    if (previousPrune.is_null() || now().seconds - integer(previousPrune) > 86400) {
        repo_->prune(now());
        index_->put("meta", "lastPrune", now().seconds);
    }
    if (verify && issues == 0) index_->put("activity", uuid(), activity("verified", "", 0, "完整校验完成"));
    if (verify && issues == 0) verifyAttempted_ = false;
    p.tracked = index_->count("file");
    p.issues = issues;
    p.state = issues ? SyncState::needsAttention : SyncState::upToDate;
    p.message = issues ? "打开活动记录查看需要处理的项目" : "";
    p.elapsedSeconds = std::chrono::duration<double>(Clock::now() - begun).count();
    p.currentPath.clear();
    view_.volume = inspect(view_.job.target);
    drain();
    publish(true);
    return p;
}

Json SyncEngine::activities() {
    auto rows = Json::array();
    if (!index_) return rows;
    std::vector<Json> records;
    for (const auto& [_, event] : index_->all("issue")) records.push_back(event);
    for (const auto& [_, event] : index_->all("activity")) records.push_back(event);
    std::sort(records.begin(), records.end(), [](const Json& a, const Json& b) {
        auto left = eventTime(a.at("date")), right = eventTime(b.at("date"));
        return std::tie(left.seconds, left.nanoseconds) > std::tie(right.seconds, right.nanoseconds);
    });
    for (size_t i = 0; i < std::min<size_t>(records.size(), 2000); ++i) rows.push_back(std::move(records[i]));
    return rows;
}
Json SyncEngine::history() {
    auto rows = Json::array();
    if (!index_) return rows;
    std::vector<Json> records;
    for (const auto& [_, saved] : index_->all("archive")) records.push_back(saved.at("item"));
    std::sort(records.begin(), records.end(), [](const Json& a, const Json& b) {
        auto left = eventTime(a.at("date")), right = eventTime(b.at("date"));
        return std::tie(left.seconds, left.nanoseconds) > std::tie(right.seconds, right.nanoseconds);
    });
    for (auto& item : records) rows.push_back(std::move(item));
    return rows;
}
fs::path SyncEngine::restore(const fs::path& folder, std::string_view version) {
    refresh();
    require(repo_ != nullptr, "硬盘未连接");
    Tree output(folder);
    auto destination = folded(utf8(output.root()));
    require(!inside(destination, folded(utf8(repo_->tree.root()))) && !inside(destination, folded(utf8(storage_))),
            "请选择备份目录之外的恢复位置");
    const auto temporary = ".backup-genius-restore-" + uuid();
    const auto visible = "Backup Genius Restore " + uuid();
    output.mkdir(temporary);
    int64_t skipped = 0;
    try {
        if (!version.empty()) {
            const auto saved = index_->get("archive", identifier(std::string(version)));
            require(!saved.is_null(), "此历史版本已过期");
            auto filename = name(saved.at("item").at("path").get<std::string>());
            require(representable(filename), "文件名在 Windows 无法表示");
            repo_->restore(saved, output, join(temporary, filename));
        } else {
            for (const auto& [rel, record] : index_->all("file")) {
                if (!representable(rel) || (link(record) && !record.at("attributes").value("windowsLink", false))) { ++skipped; continue; }
                auto destinationPath = join(temporary, rel);
                output.parents(destinationPath);
                if (link(record)) {
                    try { repo_->copyCurrent(record, output, destinationPath); }
                    catch (const std::system_error&) { ++skipped; }
                } else repo_->copyCurrent(record, output, destinationPath);
            }
        }
        output.rename(temporary, visible);
        output.flushDirectory();
    } catch (...) {
        try { output.removeOwned(temporary); } catch (...) {}
        throw;
    }
    if (skipped) {
        view_.progress.message = "恢复完成，" + std::to_string(skipped) + " 个链接或名称需在原平台恢复";
        view_.progress.state = SyncState::needsAttention;
        publish(true);
    }
    return output.root() / path(visible);
}
Records SyncEngine::diskSnapshot() {
    auto records = index_->all("file");
    for (const auto& [rel, record] : records) {
        if (!safeEntry(rel, record)) continue;
        const auto before = repo_->tree.entry(rel);
        require(before && kindName(before->kind) == record.at("source").at("kind").get<std::string>(), "硬盘文件与日志不符，请先校验");
        if (before->kind == Kind::regular)
            require(before->size == integer(record.at("source").at("size")) &&
                    base64(hashFile(repo_->tree.file(rel), before->size)) == record.at("hashes").get<std::string>() &&
                    repo_->tree.entry(rel) == before, "硬盘文件已在其他程序中改写，请在原电脑校验");
    }
    repo_->tree.check();
    return records;
}
TakeoverPreview SyncEngine::previewTakeover(const fs::path& folder) {
    refresh();
    require(repo_ != nullptr, "请先打开要接管的备份");
    const auto source = Tree(folder);
    validateFolders(source.root(), repo_->tree.root(), storage_);
    auto draft = std::make_unique<Draft>();
    draft->source = source.root();
    draft->identity = source.identity().identity;
    const auto checkpoint = index_->get("meta", "alignment");
    if (!checkpoint.is_null()) {
        require(checkpoint.at("source") == draft->identity, "请选择上次接管使用的源文件夹");
        draft->preview = {identifier(checkpoint.at("id")), repo_->generation, {}, true};
    } else {
        draft->local = sourceSnapshot(source);
        const bool bound = index_->get("meta", "binding") == draft->identity;
        require(bound || draft->local.empty(), "首次接管请选择空文件夹");
        draft->disk = diskSnapshot();
        const auto base = bound ? index_->all("base") : Records{};
        draft->preview = {uuid(), repo_->generation, {}, false};
        std::set<std::string> paths;
        std::map<std::string, std::string> names;
        std::set<std::string> collisions;
        auto track = [&](const Records& records) {
            for (const auto& [rel, _] : records) {
                paths.insert(rel);
                auto [it, inserted] = names.emplace(folded(rel), rel);
                if (!inserted && it->second != rel) { collisions.insert(it->second); collisions.insert(rel); }
            }
        };
        track(draft->local);
        track(draft->disk);
        for (const auto& rel : paths) {
            const auto local = lookup(draft->local, rel);
            const auto remote = lookup(draft->disk, rel);
            const auto prior = lookup(base, rel);
            if (link(remote) && link(local) && sameContent(local, remote)) continue;
            if (!safeEntry(rel, remote) || !safeEntry(rel, local) || collisions.contains(rel) ||
                (!local.is_null() && !remote.is_null() && directory(local) != directory(remote))) {
                draft->preview.changes.push_back({rel, AlignmentKind::blocked, false});
            } else if (!sameContent(local, remote)) {
                auto kind = sameContent(local, prior) ? AlignmentKind::receive :
                    (sameContent(remote, prior) ? AlignmentKind::send : AlignmentKind::conflict);
                draft->preview.changes.push_back({rel, kind, !local.is_null() && !remote.is_null() && !directory(local) && !directory(remote)});
            }
        }
    }
    auto preview = draft->preview;
    draft_ = std::move(draft);
    return preview;
}

void SyncEngine::confirmTakeover(std::string_view preview, const std::map<std::string, AlignmentChoice>& choices) {
    require(draft_ && draft_->preview.id == preview && repo_, "请重新预览接管");
    const auto source = Tree(draft_->source);
    require(source.identity().identity == draft_->identity, "源文件夹已替换");
    auto plan = index_->get("meta", "alignment");
    if (draft_->preview.resuming) {
        require(plan.at("id") == preview && plan.at("source") == draft_->identity &&
                (plan.at("writer") == repo_->owner || repo_->owner == host_) &&
                equalSnapshots(diskSnapshot(), plan.at("disk").get<Records>()), "备份内容已变更，无法继续上次接管");
    } else {
        require(repo_->generation == draft_->preview.generation && equalSnapshots(sourceSnapshot(source), draft_->local) &&
                equalSnapshots(diskSnapshot(), draft_->disk), "预览已过期，请重新检查文件");
        std::vector<Json> copies, removals, updates;
        for (const auto& change : draft_->preview.changes) {
            if (change.kind == AlignmentKind::send) continue;
            if (change.kind == AlignmentKind::blocked) {
                // Unsupported foreign entries remain in the catalog and are never
                // used as evidence that the newly aligned source deleted them.
                require(!safeEntry(change.path, lookup(draft_->disk, change.path)) &&
                        lookup(draft_->local, change.path).is_null(), "请先处理预览中的名称、链接或类型冲突");
                continue;
            }
            const auto local = lookup(draft_->local, change.path);
            const auto remote = lookup(draft_->disk, change.path);
            if (change.kind == AlignmentKind::conflict) {
                auto choice = choices.find(change.path);
                require(choice != choices.end(), "请为每项冲突选择处理方式");
                if (choice->second == AlignmentChoice::local) continue;
                if (choice->second == AlignmentChoice::both) {
                    require(change.canKeepBoth, "此冲突无法保留两份");
                    const auto copy = join(parent(change.path), "Backup Genius conflict " + uuid());
                    copies.push_back({{"path", copy}, {"before", nullptr}, {"desired", local}, {"copyLocal", change.path}, {"archive", uuid()}});
                }
            }
            auto step = Json{{"path", change.path}, {"before", local}, {"desired", remote}, {"archive", uuid()}};
            (remote.is_null() ? removals : updates).push_back(std::move(step));
        }
        auto deeper = [](const Json& a, const Json& b) { return depth(a.at("path").get<std::string>()) > depth(b.at("path").get<std::string>()); };
        std::sort(removals.begin(), removals.end(), deeper);
        std::sort(updates.rbegin(), updates.rend(), deeper);
        copies.insert(copies.end(), removals.begin(), removals.end());
        copies.insert(copies.end(), updates.begin(), updates.end());
        plan = {{"id", preview}, {"source", draft_->identity}, {"writer", repo_->owner}, {"disk", draft_->disk}, {"steps", copies}};
        index_->put("meta", "alignment", plan);
    }
    view_.job.source = source.root();
    view_.job.sourceId = draft_->identity;
    if (view_.job.restoreOnly) view_.job.automatic = true;
    view_.job.restoreOnly = false;
    saveJob();
    paused_ = false;
    view_.progress.state = SyncState::recovering;
    view_.progress.message = "正在对齐源文件夹";
    publish(true);
    repo_->upgrade();
    for (const auto& step : plan.at("steps")) {
        if (paused_) throw Paused();
        auto rel = step.at("path").get<std::string>();
        require(validPath(rel) && representable(rel), "无效接管路径");
        auto current = source.entry(rel);
        auto local = current ? snapshotFile(source, rel, *current) : Json(nullptr);
        const auto& desired = step.at("desired");
        if (sameContent(local, desired)) continue;
        require(sameContent(local, step.at("before")), "接管期间源文件已变化");
        const auto id = identifier(step.at("archive"));
        if (current && index_->get("archive", id).is_null()) {
            auto batch = repo_->batch();
            PackWriter writer(*repo_, identifier(batch.at("id")));
            if (current->kind == Kind::regular) {
                int64_t read{};
                local["hashes"] = writer.saveFile(source, rel, *current, unbase64(local.at("hashes").get<std::string>()), read);
            }
            auto edit = makeEdit("archive", rel, {});
            edit["archive"] = archiveVersion(local, "updated", id);
            edit["activity"] = activity("updated", rel, 0, "接管前归档本机文件");
            batch["edits"].push_back(edit);
            batch["chunks"] = writer.finish();
            repo_->commit(batch, {}, [&] { require(source.entry(rel) == current, "归档后源文件已变化"); });
        }
        if (desired.is_null()) {
            require(source.entry(rel) == current, "接管期间源文件已变化");
            source.remove(rel, true);
            source.flushDirectory(parent(rel));
        } else if (directory(desired)) {
            source.mkdir(rel);
            source.flushDirectory(parent(rel));
        } else {
            source.parents(rel);
            auto temp = join(parent(rel), ".backup-genius-align-" + id);
            if (source.entry(temp)) source.remove(temp);
            if (exists(step, "copyLocal")) {
                auto in = source.file(step.at("copyLocal").get<std::string>());
                auto out = source.file(temp, File::Mode::create);
                copyChecked(in, out, integer(desired.at("source").at("size")), unbase64(desired.at("hashes").get<std::string>()));
                setMeta(source, temp, desired.at("attributes"));
            } else repo_->copyCurrent(desired, source, temp);
            require(source.entry(rel) == current, "接管期间源文件已变化");
            source.rename(temp, rel, current.has_value());
            source.flushDirectory(parent(rel));
        }
    }
    source.check();
    repo_->claim();
    repo_->bind(view_.job.sourceId);
    index_->remove("meta", "alignment");
    sourceWatch_.reset();
    sourceGap_ = true;
    recordChanges({{}, true});
    recordChanges({{}, true}, true);
    draft_.reset();
    view_.progress.state = SyncState::ready;
    view_.progress.message.clear();
    publish(true);
}
}
