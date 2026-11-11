#include "BackupSet.h"

#include <algorithm>
#include <set>
#include <stdexcept>

namespace bg {
namespace {
const auto records = join(storageFolder, "set");
const auto pending = join(records, "pending.json");
const auto marker = join(backupRoot, identityFile);
void require(bool result, const char* message) { if (!result) throw std::runtime_error(message); }

bool folderPath(std::string_view path) {
    return validPath(path, false) && std::count(path.begin(), path.end(), '/') <= 1 &&
        !backupControl(path) && !backupControl(name(path));
}
std::string prepareLock(const Tree& disk) {
    disk.mkdir(storageFolder);
    disk.hide(storageFolder);
    disk.mkdir(records);
    disk.flushDirectory(storageFolder);
    disk.flushDirectory();
    return join(records, "lock");
}
bool exactDirectory(const Tree& disk, std::string_view path) {
    const auto stamp = disk.entry(path);
    if (!stamp || stamp->kind != Kind::directory) return false;
    const auto entries = disk.children(parent(path));
    return std::find(entries.begin(), entries.end(), name(path)) != entries.end();
}
void checkWitness(const Tree& disk, const std::string& path, const SetMove& move, int64_t revision) {
    const auto witness = Json::parse(disk.readDocument(path));
    require(identifier(witness.at("job")) == move.job && integer(witness.at("revision")) == revision,
            "移动中的备份文件夹与恢复记录不符");
}
void validate(const SetTransition& change, const std::optional<BackupSet>& current, std::string_view format) {
    const auto next = readSet(setDocument(change.next));
    const bool published = current == next;
    require(next.format == format && change.base >= 0 && change.base < INT64_MAX && next.revision == change.base + 1 &&
        (published || (current ? current->revision == change.base && current->id == next.id : change.base == 0)),
        "备份映射已改变，请重新预览");
    std::map<std::string, FolderMapping> old, updated;
    if (current) for (const auto& map : current->mappings) old.emplace(map.job, map);
    for (const auto& map : next.mappings) updated.emplace(map.job, map);
    std::set<std::string> additions, moves;
    for (const auto& entry : change.additions) {
        const auto job = identifier(entry.at("job"));
        require(integer(entry.at("version")) == 2 && !identifier(entry.at("initialWriter")).empty() &&
                integer(entry.at("legacyGeneration")) == 0 && entry.at("format") == next.format &&
                updated.contains(job) && additions.insert(job).second,
                "备份集合的恢复记录无效");
    }
    for (const auto& move : change.moves) {
        require(folderPath(move.from) && updated.contains(move.job) && updated.at(move.job).folder == move.to &&
                (published || (old.contains(move.job) && old.at(move.job).folder == move.from)) &&
                moves.insert(move.job).second, "备份集合的移动记录无效");
    }
    if (!published) {
        for (const auto& [id, map] : old)
            require(updated.contains(id) && updated.at(id).id == map.id, "备份集合的任务标识不符");
        for (const auto& [id, map] : updated)
            require(additions.contains(id) == !old.contains(id) &&
                    moves.contains(id) == (old.contains(id) && old.at(id).folder != map.folder),
                    "备份集合的恢复记录不完整");
    }
}
}

Json setDocument(const BackupSet& set) {
    auto mappings = Json::array();
    for (const auto& mapping : set.mappings)
        mappings.push_back({{"id", mapping.id}, {"job", mapping.job}, {"folder", mapping.folder}, {"enabled", mapping.enabled}});
    return {{"layout", 2}, {"id", set.id}, {"format", set.format}, {"revision", set.revision}, {"mappings", mappings}};
}
BackupSet readSet(const Json& document) {
    require(integer(document.at("layout")) == 2 && document.at("mappings").is_array(), "备份集合的识别记录无效");
    BackupSet set{identifier(document.at("id")), document.at("format"), integer(document.at("revision")), {}};
    require(set.revision > 0 && !document.at("mappings").empty() &&
        (set.format == "ntfs" || set.format == "exfat"), "备份集合的识别记录无效");
    std::set<std::string> ids, jobs, paths;
    for (const auto& entry : document.at("mappings")) {
        FolderMapping mapping{identifier(entry.at("id")), identifier(entry.at("job")), entry.at("folder"), entry.at("enabled")};
        require(folderPath(mapping.folder) && ids.insert(mapping.id).second &&
            jobs.insert(mapping.job).second && paths.insert(folded(mapping.folder)).second, "备份集合中的文件夹位置冲突");
        set.mappings.push_back(std::move(mapping));
    }
    for (const auto& folder : paths)
        require(!paths.contains(parent(folder)), "备份集合中的文件夹位置重叠");
    return set;
}
BackupSetStore::BackupSetStore(Volume info, std::function<void(SetInterruption)> fault)
    : disk(info.mount), volume(std::move(info)), lease_(disk.checked(prepareLock(disk))), fault_(std::move(fault)) {}
std::optional<BackupSet> BackupSetStore::read(const Tree& disk, std::string_view format) {
    if (!disk.entry(marker)) return {};
    auto set = readSet(Json::parse(disk.readDocument(marker)));
    require(set.format == format, "备份集合与硬盘格式不符");
    return set;
}
std::optional<BackupSet> BackupSetStore::recover() {
    disk.check();
    if (!disk.entry(pending)) return read(disk, volume.format);
    const auto envelope = Json::parse(disk.readDocument(pending));
    const auto body = unbase64(envelope.at("body").get<std::string>());
    require(sha256(body) == unbase64(envelope.at("checksum").get<std::string>()), "备份记录校验失败");
    const auto saved = Json::parse(body);
    SetTransition change{integer(saved.at("base")), readSet(saved.at("next")), saved.at("additions"), {}};
    for (const auto& entry : saved.at("moves"))
        change.moves.push_back({entry.at("from"), entry.at("to"), identifier(entry.at("job"))});
    finish(change);
    return change.next;
}
void BackupSetStore::apply(const SetTransition& change) {
    disk.check();
    require(!disk.entry(pending), "请先恢复未完成的目录调整");
    const auto current = read(disk, volume.format);
    validate(change, current, volume.format);
    checkRootSlot(current.has_value());
    for (const auto& map : change.next.mappings)
        if (representable(map.folder)) checkTargetSlot(map.folder);
    auto moves = Json::array();
    for (const auto& move : change.moves) {
        require(exactDirectory(disk, join(backupRoot, move.from)), "找不到要移动的备份文件夹");
        require(folded(move.from) == folded(move.to) || !disk.entry(join(backupRoot, move.to)), "备份文件夹位置已被占用");
        moves.push_back({{"from", move.from}, {"to", move.to}, {"job", move.job}});
    }
    const Json body = {{"base", change.base}, {"next", setDocument(change.next)}, {"additions", change.additions}, {"moves", moves}};
    const auto bytes = body.dump();
    const Json envelope = {{"body", base64(bytes)}, {"checksum", base64(sha256(bytes))}};
    disk.writeDocument(pending, envelope.dump());
    if (fault_) fault_(SetInterruption::prepared);
    finish(change);
}
void BackupSetStore::finish(const SetTransition& change) {
    const auto current = read(disk, volume.format);
    validate(change, current, volume.format);
    if (current != change.next) {
        checkRootSlot(current.has_value());
        disk.mkdir(backupRoot);
        for (const auto& move : change.moves) relocate(move, change.next.revision);
        for (const auto& metadata : change.additions) {
            const auto id = identifier(metadata.at("job"));
            const auto member = std::find_if(change.next.mappings.begin(), change.next.mappings.end(),
                [&](const auto& map) { return map.job == id; });
            checkTargetSlot(member->folder);
            const auto target = join(backupRoot, member->folder);
            disk.parents(target);
            disk.mkdir(target);
            Repository::initializeMember(disk, target, metadata);
            disk.flushDirectory(parent(target));
        }
        disk.writeDocument(marker, setDocument(change.next).dump(), current.has_value(), records, true);
        if (fault_) fault_(SetInterruption::published);
    }
    for (const auto& move : change.moves) {
        const auto witness = join(join(backupRoot, move.to), identityFile);
        if (disk.entry(witness)) {
            checkWitness(disk, witness, move, change.next.revision);
            disk.remove(witness);
            disk.flushDirectory(parent(witness));
        }
    }
    disk.remove(pending);
    disk.flushDirectory(records);
}
void BackupSetStore::relocate(const SetMove& move, int64_t revision) {
    const auto from = join(backupRoot, move.from), to = join(backupRoot, move.to), stage = join(records, move.job);
    if (!disk.entry(stage) && exactDirectory(disk, from)) {
        const auto witness = join(from, identityFile);
        if (!disk.entry(witness)) {
            const Json value = {{"job", move.job}, {"revision", revision}};
            disk.writeDocument(witness, value.dump(), false, records, true);
        }
        checkWitness(disk, witness, move, revision);
        disk.rename(from, stage);
        disk.flushDirectory(parent(from));
        disk.flushDirectory(records);
        if (fault_) fault_(SetInterruption::relocated);
    }
    if (disk.entry(stage)) {
        checkWitness(disk, join(stage, identityFile), move, revision);
        disk.parents(to);
        disk.rename(stage, to);
        disk.flushDirectory(parent(to));
        disk.flushDirectory(records);
    }
    checkWitness(disk, join(to, identityFile), move, revision);
}
void BackupSetStore::checkRootSlot(bool existing) {
    const auto root = disk.entry(backupRoot);
    require(!root || root->kind == Kind::directory, "硬盘上的 BackupGenius 名称已被占用");
    require(!disk.entry(control) && !disk.entry(identityFile) && !disk.entry(join(backupRoot, control)) &&
            (existing || !disk.entry(join(backupRoot, "._.backup-genius.json"))), "备份位置与已有任务重叠");
}
void BackupSetStore::checkTargetSlot(std::string_view folder) {
    const auto slot = [&](const std::string& relative) {
        if (const auto stamp = disk.entry(relative))
            require(stamp->kind == Kind::directory && !disk.entry(join(relative, control)) &&
                    !disk.entry(join(relative, identityFile)), "目标文件夹与已有任务或文件冲突");
    };
    if (!parent(folder).empty()) slot(join(backupRoot, parent(folder)));
    slot(join(backupRoot, folder));
}
}
