#include "RestorePoints.h"
#include "Watch.h"
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <set>
#include <stdexcept>

namespace bg {
namespace {
const std::string root = ".backup-genius/points";
void require(bool condition, const char* reason) { if (!condition) throw std::runtime_error(reason); }
std::string pointName(size_t index) { std::ostringstream out; out << std::setw(20) << std::setfill('0') << index << ".json"; return out.str(); }
bool pointContentEqual(const Json& a, const Json& b) {
    return a.at("source").at("kind") == b.at("source").at("kind") &&
           a.at("source").at("size") == b.at("source").at("size") &&
           a.value("hashes", "") == b.value("hashes", "") && a.value("link", Json()) == b.value("link", Json());
}
}
Json RestorePointStore::read(std::string_view path) const {
    const auto sealed = Json::parse(repo_.tree.readDocument(join(root, path)));
    const auto bytes = unbase64(sealed.at("body").get<std::string>());
    require(sha256(bytes) == unbase64(sealed.at("checksum").get<std::string>()), "备份时间点记录校验失败");
    return Json::parse(bytes);
}
void RestorePointStore::write(std::string_view path, const Json& value) const {
    auto bytes = value.dump();
    repo_.tree.writeDocument(join(root, path), Json{{"body", base64(bytes)}, {"checksum", base64(sha256(bytes))}}.dump());
}
RestorePointStore::RestorePointStore(Repository& repository, Fault fault) : repo_(repository), fault_(std::move(fault)) {
    if (!repo_.tree.entry(root)) return;
    if (!repo_.tree.entry(root + "/records") && repo_.tree.children(root).empty()) return;
    auto names = repo_.tree.children(root + "/records");
    std::erase_if(names, [](const auto& value) { return value.starts_with('.') || !value.ends_with(".json"); });
    std::sort(names.begin(), names.end());
    std::string previous;
    for (const auto& name : names) {
        auto point = read("records/" + name);
        require(integer(point.at("version")) == 1 && integer(point.at("sequence")) == static_cast<int64_t>(points_.size() + 1) &&
                name == pointName(points_.size() + 1) && point.value("previous", "") == previous,
                "备份时间点记录顺序异常");
        previous = identifier(point.at("id"));
        decodeTime(point.at("created"));
        require(integer(point.at("files")) >= 0, "时间点文件数量无效");
        points_.push_back(point);
    }
}
void RestorePointStore::loadContents() {
    if (contentsLoaded_) return;
    for (const auto& point : points_) apply(point, entries_);
    if (!repo_.tree.entry(root)) { contentsLoaded_ = true; return; }
    const auto packs = repo_.tree.children(root + "/packs");
    std::set<std::string> present(packs.begin(), packs.end());
    std::erase_if(chunks_, [&](const auto& pair) { return !present.contains(identifier(pair.second.at("pack"))); });
    contentsLoaded_ = true;
}
void RestorePointStore::apply(const Json& point, Records& state, bool collect, const std::function<void(const Json&)>& visit) {
    for (const auto& id : point.at("segments")) {
        if (collect) committedSegments_.insert(identifier(id));
        auto segment = read("segments/" + identifier(id));
        for (const auto& chunk : segment.at("chunks")) {
            const auto hash = unbase64(chunk.at("hash").get<std::string>());
            const auto offset = integer(chunk.at("offset")), length = integer(chunk.at("length"));
            require(hash.size() == 32 && offset >= 0 && length > 0 && length <= blockSize && offset <= INT64_MAX - length,
                    "时间点数据位置无效");
            identifier(chunk.at("pack"));
            if (collect) { chunks_[hash] = chunk; committedPacks_.insert(identifier(chunk.at("pack"))); }
        }
        for (const auto& entry : segment.at("entries")) {
            const auto path = entry.at("path").get<std::string>();
            require(validPath(path), "时间点路径无效");
            if (exists(entry, "record")) {
                const auto& record = entry.at("record");
                const auto size = integer(record.at("source").at("size"));
                require(record.at("path") == path && size >= 0 && !exists(entry, "clone"), "此时间点需要在 Mac 上恢复");
                const auto hashes = unbase64(record.value("hashes", ""));
                if (record.at("source").at("kind") == "regular")
                    require(hashes.size() % 32 == 0 && static_cast<uint64_t>(size / blockSize + (size % blockSize != 0)) == hashes.size() / 32,
                            "时间点校验值不完整");
                state[path] = entry;
                if (visit) visit(entry);
            } else state.erase(path);
        }
    }
}
Json RestorePointStore::list(Time at) const {
    auto values = Json::array();
    for (auto item = points_.rbegin(); item != points_.rend(); ++item) {
        if (item == points_.rbegin() || decodeTime(item->at("created")).seconds >= at.seconds - 30 * 86400)
            values.push_back({{"id", item->at("id")}, {"date", item->at("created")}, {"files", item->at("files")}});
    }
    return values;
}
Json RestorePointStore::capture(const std::function<void(size_t)>& onRead, const std::function<void(size_t)>& onWrite, const std::function<void()>& checkCancellation) {
    for (const auto& path : {root, root + "/records", root + "/segments", root + "/packs", root + "/clones"}) repo_.tree.mkdir(path);
    if (checkCancellation) checkCancellation();
    if (!points_.empty() && points_.back().value("generation", int64_t{-1}) == repo_.generation) {
        Json point{{"version", 1}, {"id", uuid()}, {"sequence", points_.size() + 1}, {"generation", repo_.generation},
            {"created", encodeTime(now())}, {"files", points_.back().at("files")}, {"segments", Json::array()}, {"previous", points_.back().at("id")}};
        if (fault_) fault_(Interruption::pointPrepared);
        write("records/" + pointName(points_.size() + 1), point);
        if (fault_) fault_(Interruption::pointCommitted);
        points_.push_back(point);
        return point;
    }
    loadContents();
    for (const auto& [directory, referenced] : std::vector<std::pair<std::string, const std::set<std::string>*>>{
             {"packs", &committedPacks_}, {"segments", &committedSegments_}}) {
        for (const auto& name : repo_.tree.children(root + "/" + directory)) {
            if (name.starts_with('.')) continue;
            if (!referenced->contains(identifier(name))) repo_.tree.remove(root + "/" + directory + "/" + name);
        }
    }
    Json changes = Json::array(), locations = Json::array(), segments = Json::array();
    std::set<std::string> seen;
    std::optional<File> pack;
    std::string packID = uuid();
    int64_t offset = 0, count = 0;
    auto flush = [&] {
        if (changes.empty()) return;
        if (pack) { pack->flush(); repo_.tree.flushDirectory(root + "/packs"); }
        auto id = uuid();
        write("segments/" + id, {{"entries", changes}, {"chunks", locations}});
        segments.push_back(id);
        changes.clear(); locations.clear(); pack.reset(); packID = uuid(); offset = 0;
    };
    for (const auto& [path, record] : repo_.index.all("file")) {
        if (checkCancellation) checkCancellation();
        require(validPath(path), "时间点路径无效");
        seen.insert(path);
        if (record.at("source").at("kind") != "directory") ++count;
        const auto old = entries_.find(path);
        const bool same = old != entries_.end() && pointContentEqual(old->second.at("record"), record);
        if (same && old->second.at("record").at("attributes") == record.at("attributes")) continue;
        if (record.at("source").at("kind") == "regular" && !same) {
            auto input = repo_.tree.file(path);
            const auto before = input.stamp();
            auto stable = [&](bool value) {
                if (!value) {
                    repo_.index.put("targetDirty", path, contentChange);
                    throw std::runtime_error("等待备份文件稳定：" + path);
                }
            };
            stable(before.size == integer(record.at("source").at("size")));
            const auto hashes = unbase64(record.at("hashes").get<std::string>());
            for (size_t block = 0; block < hashes.size() / 32; ++block) {
                if (checkCancellation) checkCancellation();
                const auto hash = hashes.substr(block * 32, 32);
                if (chunks_.contains(hash)) continue;
                const auto start = static_cast<int64_t>(block) * blockSize;
                const auto length = static_cast<size_t>(std::min(blockSize, before.size - start));
                auto data = input.read(start, length);
                if (onRead) onRead(data.size());
                stable(data.size() == length && sha256(data) == hash);
                if (!pack) pack.emplace(repo_.tree.file(root + "/packs/" + packID, File::Mode::create));
                pack->write(offset, data);
                if (onWrite) onWrite(data.size());
                Json location{{"hash", base64(hash)}, {"pack", packID}, {"offset", offset}, {"length", data.size()}};
                chunks_[hash] = location;
                locations.push_back(location);
                offset += static_cast<int64_t>(data.size());
            }
            stable(before == input.stamp());
        }
        changes.push_back({{"path", path}, {"record", record}});
        if (changes.size() >= IOProfile::batchSize) flush();
    }
    for (const auto& [path, entry] : entries_) if (!seen.contains(path)) {
        changes.push_back({{"path", path}});
        if (changes.size() >= IOProfile::batchSize) flush();
    }
    flush();
    if (fault_) fault_(Interruption::pointPrepared);
    Json point{{"version", 1}, {"id", uuid()}, {"sequence", points_.size() + 1},
               {"created", encodeTime(now())}, {"files", count}, {"segments", segments}, {"generation", repo_.generation}};
    if (!points_.empty()) point["previous"] = points_.back().at("id");
    write("records/" + pointName(points_.size() + 1), point);
    if (fault_) fault_(Interruption::pointCommitted);
    points_.push_back(point);
    apply(point, entries_);
    return point;
}
void RestorePointStore::restore(std::string_view id, const Tree& output, std::string_view folder) {
    auto allowed = list();
    require(std::any_of(allowed.begin(), allowed.end(), [&](const auto& v) { return v.at("id") == id; }), "时间点已过期或不存在");
    loadContents();
    Records snapshot;
    for (const auto& point : points_) { apply(point, snapshot, false); if (point.at("id") == id) break; }
    std::vector<std::pair<std::string, Json>> metadata;
    for (const auto& [path, entry] : snapshot) {
        require(representable(path), "此时间点含有 Windows 无法表示的名称，请在 Mac 上恢复");
        const auto& record = entry.at("record");
        auto destination = join(folder, path);
        output.parents(destination);
        auto kind = record.at("source").at("kind").get<std::string>();
        const auto& attrs = record.at("attributes");
        if (kind == "regular") {
            auto file = output.file(destination, File::Mode::create);
            auto hashes = unbase64(record.at("hashes").get<std::string>());
            int64_t offset = 0;
            for (size_t block = 0; block < hashes.size() / 32; ++block) {
                const auto hash = hashes.substr(block * 32, 32);
                require(chunks_.contains(hash), "时间点文件数据缺失");
                const auto& chunk = chunks_.at(hash);
                auto input = repo_.tree.file(root + "/packs/" + identifier(chunk.at("pack")));
                auto data = input.read(integer(chunk.at("offset")), static_cast<size_t>(integer(chunk.at("length"))));
                require(sha256(data) == hash, "时间点文件内容校验失败");
                file.write(offset, data); offset += static_cast<int64_t>(data.size());
            }
            require(offset == integer(record.at("source").at("size")), "时间点文件大小不符");
            file.flush();
        } else if (kind == "directory") output.mkdir(destination);
        else if (kind == "symlink") {
            auto target = unbase64(record.at("link").get<std::string>());
            require(attrs.value("windowsLink", false) || (validPath(target, false) && representable(target)), "此链接需在 Mac 上恢复");
            output.createLink(destination, target, attrs.value("windowsLinkDirectory", false));
        } else throw std::runtime_error("不支持的文件类型");
        if (kind != "symlink") metadata.emplace_back(destination, attrs);
    }
    std::sort(metadata.begin(), metadata.end(), [](const auto& a, const auto& b) { return a.first.size() > b.first.size(); });
    for (const auto& [path, attrs] : metadata)
        output.metadata(path, decodeTime(attrs.at("modified")), decodeTime(attrs.at("birth")), attrs.value("windows", uint32_t{}));
}
void RestorePointStore::prune(Time at) {
    loadContents();
    auto kept = list(at);
    std::set<std::string> ids, packs;
    for (const auto& item : kept) ids.insert(identifier(item.at("id")));
    Records state;
    auto retain = [&](const Json& entry) {
        const auto& record = entry.at("record");
        if (record.at("source").at("kind") != "regular") return;
        auto hashes = unbase64(record.value("hashes", ""));
        for (size_t block = 0; block < hashes.size() / 32; ++block) {
            auto location = chunks_.find(hashes.substr(block * 32, 32));
            if (location != chunks_.end()) packs.insert(identifier(location->second.at("pack")));
        }
    };
    bool retaining = false;
    for (const auto& point : points_) {
        apply(point, state, false, [&](const Json& entry) { if (retaining) retain(entry); });
        if (!retaining && ids.contains(identifier(point.at("id")))) {
            retaining = true;
            for (const auto& [path, entry] : state) retain(entry);
        }
    }
    for (const auto& name : repo_.tree.children(root + "/packs")) {
        if (name.starts_with('.')) continue;
        const auto id = identifier(name);
        if (!packs.contains(id)) { if (fault_) fault_(Interruption::pointPruning); repo_.tree.remove(root + "/packs/" + name); }
    }
    std::erase_if(chunks_, [&](const auto& pair) { return !packs.contains(identifier(pair.second.at("pack"))); });
}
}
