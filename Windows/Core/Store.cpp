#include "Store.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <system_error>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winsqlite3.h>
#else
#include <fcntl.h>
#include <sqlite3.h>
#include <sys/file.h>
#include <unistd.h>
#endif

namespace bg {
namespace {
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
std::string textColumn(sqlite3_stmt* stmt, int col) {
    auto value = sqlite3_column_text(stmt, col);
    return value ? std::string(reinterpret_cast<const char*>(value), sqlite3_column_bytes(stmt, col)) : "";
}
std::string stringValue(const Json& value, const char* key) {
    return exists(value, key) ? value.at(key).get<std::string>() : "";
}
void recipeCheck(const Json& stamp, std::string_view hashes) {
    auto size = integer(stamp.at("size"));
    require(size >= 0, "文件大小无效");
    auto kind = stamp.at("kind").get<std::string>();
    require(kind == "regular" || kind == "directory" || kind == "symlink", "备份文件类型无效");
    auto count = kind == "regular" ? size / blockSize + (size % blockSize != 0) : 0;
    require(hashes.size() % 32 == 0 && static_cast<uint64_t>(count) == hashes.size() / 32, "文件块清单无效");
}
Json envelope(const Json& body) {
    auto bytes = body.dump();
    return {{"body", base64(bytes)}, {"checksum", base64(sha256(bytes))}};
}
void setMeta(const Tree& tree, std::string_view path, const Json& attrs, bool readOnly = false) {
    tree.metadata(path, decodeTime(attrs.at("modified")), decodeTime(attrs.at("birth")),
                  attrs.value("windows", uint32_t{}), readOnly);
}
bool matches(const Tree& tree, std::string_view path, const Json& stamp, std::string_view hashes) {
    auto actual = tree.entry(path);
    if (!actual || kindName(actual->kind) != stamp.at("kind").get<std::string>()) return false;
    if (actual->kind == Kind::directory) return true;
    return actual->kind == Kind::regular && actual->size == integer(stamp.at("size")) &&
        hashFile(tree.file(path), actual->size) == hashes;
}
Json versionStamp(const Json& version) {
    return {{"kind", version.at("kind")}, {"size", version.at("item").at("size")}};
}
void publishRestored(Repository& repo, const Json& version, const Json& additional, std::string_view rel) {
    auto staged = join(stagePath, uuid());
    repo.restore(version, repo.tree, staged, additional);
    auto target = repo.tree.entry(rel);
    if (target && target->kind == Kind::directory) {
        require(version.at("kind") == "directory", "恢复位置已有文件夹");
        repo.tree.remove(staged);
    } else {
        repo.tree.rename(staged, rel, target.has_value());
    }
}
}

bool exists(const Json& value, std::string_view key) {
    auto item = value.find(std::string(key));
    return item != value.end() && !item->is_null();
}
std::string identifier(const Json& json) {
    auto value = json.get<std::string>();
    require(value.size() == 36, "备份标识长度无效");
    for (size_t i = 0; i < value.size(); ++i) {
        auto& c = value[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            require(c == '-', "备份标识无效");
        } else {
            if (c >= 'a' && c <= 'f') c -= 'a' - 'A';
            require((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'), "备份标识无效");
        }
    }
    return value;
}
int64_t integer(const Json& value) {
    require(value.is_number_integer(), "需要无损整数");
    if (value.is_number_unsigned()) require(value.get<uint64_t>() <= static_cast<uint64_t>(INT64_MAX), "整数超出范围");
    return value.get<int64_t>();
}
Json encodeTime(Time value) { return {{"seconds", value.seconds}, {"nanoseconds", value.nanoseconds}}; }
Time decodeTime(const Json& json) {
    auto nanos = integer(json.at("nanoseconds"));
    auto seconds = integer(json.at("seconds"));
    require(nanos >= 0 && nanos < 1'000'000'000 && seconds >= -11644473600LL && seconds < 900000000000LL, "无效时间");
    return {seconds, static_cast<int32_t>(nanos)};
}
Time eventTime(const Json& value) {
    if (value.is_object()) return decodeTime(value);
    require(value.is_number(), "无效的旧版时间");
    auto ticks = value.get<double>() + 978307200.0;
    require(std::isfinite(ticks) && ticks >= -11644473600LL && ticks < 900000000000LL, "无效的旧版时间");
    const auto seconds = std::floor(ticks);
    auto nanos = static_cast<int64_t>(std::llround((ticks - seconds) * 1e9));
    return {static_cast<int64_t>(seconds) + nanos / 1'000'000'000, static_cast<int32_t>(nanos % 1'000'000'000)};
}
std::string kindName(Kind kind) {
    switch (kind) {
    case Kind::regular: return "regular";
    case Kind::directory: return "directory";
    case Kind::link: return "symlink";
    case Kind::unsupported: return "unsupported";
    }
    throw std::logic_error("unknown file kind");
}
Json portableStamp(const Stamp& stamp) {
    return {{"kind", kindName(stamp.kind)}, {"size", stamp.size}, {"modified", encodeTime(stamp.modified)},
            {"changed", encodeTime({})}, {"birth", encodeTime({})}, {"mode", 0}, {"links", 0}, {"flags", 0}, {"inode", 0}};
}
Json observedStamp(const Stamp& stamp) {
    return {{"kind", kindName(stamp.kind)}, {"size", stamp.size}, {"id", stamp.identity},
            {"modified", encodeTime(stamp.modified)}, {"changed", encodeTime(stamp.changed)}, {"attributes", stamp.attributes}};
}
Json attributes(const Stamp& stamp, const Json& inherited) {
    auto result = inherited.is_object() ? inherited : Json::object();
    if (!result.contains("mode")) result["mode"] = stamp.kind == Kind::directory ? 0755 : 0644;
    if (!result.contains("extended")) result["extended"] = Json::object();
    result["modified"] = encodeTime(stamp.modified);
    result["birth"] = encodeTime(stamp.created);
    result["windows"] = stamp.attributes;
    return result;
}
Json recipe(std::string path, const Stamp& stamp, std::string_view hashes, const Json& inherited) {
    auto id = exists(inherited, "portableID") ? identifier(inherited.at("portableID")) : uuid();
    return {{"path", std::move(path)}, {"source", portableStamp(stamp)}, {"attributes", attributes(stamp,
        exists(inherited, "attributes") ? inherited.at("attributes") : Json(nullptr))}, {"hashes", base64(hashes)}, {"portableID", id}};
}
Json activity(std::string kind, std::string path, int64_t bytes, std::string detail) {
    Json value = {{"id", uuid()}, {"date", encodeTime(now())}, {"kind", std::move(kind)}, {"path", std::move(path)}, {"bytes", bytes}};
    if (!detail.empty()) value["detail"] = std::move(detail);
    return value;
}
Json archiveVersion(const Json& record, std::string reason, std::string id) {
    auto value = Json{{"item", {{"id", id.empty() ? uuid() : id}, {"date", encodeTime(now())},
        {"path", record.at("path")}, {"size", record.at("source").at("size")}, {"reason", std::move(reason)}}},
        {"kind", record.at("source").at("kind")}, {"attributes", record.at("attributes")}, {"hashes", record.at("hashes")}};
    if (exists(record, "link")) value["link"] = record.at("link");
    return value;
}
bool sameContent(const Json& a, const Json& b) {
    if (a.is_null() || b.is_null()) return a.is_null() && b.is_null();
    return a.at("source").at("kind") == b.at("source").at("kind") &&
        a.at("source").at("size") == b.at("source").at("size") && a.at("hashes") == b.at("hashes") &&
        stringValue(a, "link") == stringValue(b, "link");
}

Index::Index(const fs::path& filename) {
    auto status = sqlite3_open_v2(utf8(filename).c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
    try {
        require(status == SQLITE_OK, "无法打开本地 SQLite 索引");
        sql("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000;"
            "CREATE TABLE IF NOT EXISTS cache (bucket TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,"
            " PRIMARY KEY(bucket,key)) WITHOUT ROWID;");
    } catch (...) { if (db_) sqlite3_close(db_); throw; }
}
Index::~Index() {
    for (auto& [_, stmt] : statements_) sqlite3_finalize(stmt);
    sqlite3_close(db_);
}
void Index::sql(const char* command) {
    if (sqlite3_exec(db_, command, nullptr, nullptr, nullptr) != SQLITE_OK) throw std::runtime_error(sqlite3_errmsg(db_));
}
void Index::statement(const char* sqlText, const std::vector<std::string_view>& args, const std::function<void(sqlite3_stmt*)>& row) {
    auto& stmt = statements_[sqlText];
    if (!stmt && sqlite3_prepare_v2(db_, sqlText, -1, &stmt, nullptr) != SQLITE_OK) throw std::runtime_error(sqlite3_errmsg(db_));
    try {
        for (size_t i = 0; i < args.size(); ++i) {
            auto value = args[i];
            if (sqlite3_bind_text(stmt, static_cast<int>(i + 1), value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT) != SQLITE_OK)
                throw std::runtime_error(sqlite3_errmsg(db_));
        }
        int status;
        while ((status = sqlite3_step(stmt)) == SQLITE_ROW) if (row) row(stmt);
        if (status != SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(db_));
    } catch (...) { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt); throw; }
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
}
Json Index::get(std::string_view bucket, std::string_view key) {
    Json value;
    statement("SELECT value FROM cache WHERE bucket=? AND key=?", {bucket, key},
              [&](sqlite3_stmt* stmt) { value = Json::parse(textColumn(stmt, 0)); });
    return value;
}
Records Index::all(std::string_view bucket) {
    Records values;
    statement("SELECT key,value FROM cache WHERE bucket=?", {bucket}, [&](sqlite3_stmt* stmt) {
        values.emplace(textColumn(stmt, 0), Json::parse(textColumn(stmt, 1)));
    });
    return values;
}
Records Index::below(std::string_view bucket, std::string_view path) {
    Records values;
    auto lower = std::string(path) + "/", upper = std::string(path) + "0";
    statement("SELECT key,value FROM cache WHERE bucket=? AND key>=? AND key<?"
              " UNION ALL SELECT key,value FROM cache WHERE bucket=? AND key=?",
              {bucket, lower, upper, bucket, path},
              [&](sqlite3_stmt* stmt) { values.emplace(textColumn(stmt, 0), Json::parse(textColumn(stmt, 1))); });
    return values;
}
int64_t Index::count(std::string_view bucket) {
    int64_t count{};
    statement("SELECT count(*) FROM cache WHERE bucket=?", {bucket}, [&](sqlite3_stmt* stmt) { count = sqlite3_column_int64(stmt, 0); });
    return count;
}
void Index::put(std::string_view bucket, std::string_view key, const Json& value) {
    auto data = value.dump();
    statement("INSERT OR REPLACE INTO cache VALUES(?,?,?)", {bucket, key, data}, {});
}
void Index::remove(std::string_view bucket, std::string_view key) {
    statement("DELETE FROM cache WHERE bucket=? AND key=?", {bucket, key}, {});
}
void Index::clear(std::string_view bucket) { statement("DELETE FROM cache WHERE bucket=?", {bucket}, {}); }
void Index::keepNewest(std::string_view bucket) {
    statement("DELETE FROM cache WHERE bucket=? AND key IN "
              "(SELECT key FROM cache WHERE bucket=? ORDER BY key DESC LIMIT -1 OFFSET 2000)", {bucket, bucket}, {});
}
void Index::transaction(const std::function<void()>& run) {
    sql("BEGIN IMMEDIATE");
    try { run(); sql("COMMIT"); }
    catch (...) { sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr); throw; }
}

Json Repository::readMarker(const Tree& tree) {
    auto value = Json::parse(tree.readDocument(markerPath));
    auto version = integer(value.at("version"));
    identifier(value.at("job"));
    const auto format = value.at("format").get<std::string>();
    require((version == 1 && format == "exfat") || (version == 2 && (format == "exfat" || format == "ntfs")),
            "仅支持 exFAT 和 NTFS 备份记录");
    if (version == 2) {
        require(integer(value.at("legacyGeneration")) >= 0, "旧版提交代次无效");
        if (exists(value, "initialWriter")) identifier(value.at("initialWriter"));
    }
    return value;
}
Json Repository::create(const Tree& tree, std::string format, std::string writer) {
    require(format == "ntfs" || format == "exfat", "目标必须为 NTFS 或 exFAT");
    if (tree.entry(control)) return readMarker(tree);
    tree.mkdir(control);
    for (const auto& dir : {journalPath, packPath, stagePath, versionsPath}) tree.mkdir(dir);
    Json marker = {{"version", 2}, {"job", uuid()}, {"format", std::move(format)}, {"initialWriter", writer}, {"legacyGeneration", 0}};
    tree.writeDocument(markerPath, marker.dump());
    tree.flushDirectory();
    return marker;
}
Repository::Repository(Tree target, Index& cache, std::string writer, Fault fault)
    : tree(std::move(target)), index(cache), host(std::move(writer)), fault_(std::move(fault)) {
    auto p = tree.checked(join(control, "lock"));
#ifdef _WIN32
    auto h = CreateFileW(p.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) throw std::system_error(GetLastError(), std::system_category(), "打开备份锁");
    OVERLAPPED range{};
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &range)) {
        CloseHandle(h);
        throw std::runtime_error("此备份正在另一个进程中使用");
    }
    lease_ = reinterpret_cast<intptr_t>(h);
#else
    auto fd = ::open(p.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (fd >= 0) close(fd);
        throw std::runtime_error("此备份正在另一个进程中使用");
    }
    lease_ = fd;
#endif
}
Repository::~Repository() {
#ifdef _WIN32
    if (lease_ != -1) CloseHandle(reinterpret_cast<HANDLE>(lease_));
#else
    if (lease_ != -1) close(static_cast<int>(lease_));
#endif
}
std::string Repository::commitPath(int64_t gen) const {
    auto number = std::to_string(gen);
    return join(journalPath, std::string(20 - number.size(), '0') + number + ".json");
}
Json Repository::readBatch(std::string_view rel) {
    auto sealed = Json::parse(tree.readDocument(rel));
    auto body = unbase64(sealed.at("body").get<std::string>());
    require(sha256(body) == unbase64(sealed.at("checksum").get<std::string>()), "备份记录校验失败");
    auto batch = Json::parse(body);
    identifier(batch.at("id"));
    auto gen = integer(batch.at("generation"));
    require(gen > 0, "无效提交代次");
    const bool portable = marker.at("version") == 2 && gen > integer(marker.at("legacyGeneration"));
    require(portable ? batch.value("version", 0) == 2 : !batch.contains("version"), "备份记录与协议版本不符");
    if (exists(batch, "writer")) identifier(batch.at("writer"));
    for (auto key : {"edits", "chunks", "pruned", "retiredPacks"}) require(batch.at(key).is_array(), "记录清单无效");
    if (batch.value("takeover", false)) {
        require(portable && exists(batch, "writer") && batch["edits"].empty() && batch["chunks"].empty() &&
                batch["pruned"].empty() && batch["retiredPacks"].empty(), "接管记录无效");
    }
    for (const auto& edit : batch.at("edits")) {
        const auto method = edit.at("method").get<std::string>();
        const auto rel = edit.at("path").get<std::string>();
        require(validPath(rel), "记录含有无效路径");
        require(method == "record" || method == "install" || method == "patch" || method == "attributes" ||
                method == "remove" || method == "move" || method == "caseMove" || (portable && method == "archive"), "未知文件操作");
        if (exists(edit, "from")) require(validPath(edit.at("from").get<std::string>()), "移动记录路径无效");
        if (exists(edit, "staging")) identifier(edit.at("staging"));
        if (exists(edit, "next")) {
            const auto& next = edit.at("next");
            require(next.at("path") == rel, "文件路径不一致");
            recipeCheck(next.at("source"), unbase64(next.at("hashes").get<std::string>()));
            if (exists(next, "portableID")) identifier(next.at("portableID"));
        }
        if (exists(edit, "archive")) {
            const auto& saved = edit.at("archive");
            require(!exists(saved, "clone"), "此文件需要 APFS 克隆");
            identifier(saved.at("item").at("id"));
            eventTime(saved.at("item").at("date"));
            require(validPath(saved.at("item").at("path").get<std::string>()), "历史路径无效");
            recipeCheck(versionStamp(saved), unbase64(saved.at("hashes").get<std::string>()));
        }
        for (const auto& block : edit.at("rollbackBlocks")) {
            const auto i = integer(block);
            require(i >= 0 && i <= INT64_MAX / blockSize, "恢复块范围无效");
        }
    }
    for (const auto& loc : batch.at("chunks")) {
        identifier(loc.at("pack"));
        auto start = integer(loc.at("offset")), size = integer(loc.at("length"));
        require(unbase64(loc.at("hash").get<std::string>()).size() == 32 && size > 0 && size <= blockSize &&
                start >= 0 && start <= INT64_MAX - size, "历史块范围无效");
    }
    for (const auto& id : batch.at("pruned")) identifier(id);
    for (const auto& id : batch.at("retiredPacks")) identifier(id);
    return batch;
}
void Repository::open() {
    tree.check();
    marker = readMarker(tree);
    const auto job = identifier(marker.at("job"));
    require(index.get("meta", "job").is_null() || index.get("meta", "job") == job, "本机索引属于另一项备份");
    index.put("meta", "job", job);
    auto gen = index.get("meta", "generation");
    generation = gen.is_null() ? 0 : integer(gen);
    auto prior = index.get("meta", "head");
    head = prior.is_null() ? "" : identifier(prior);
    auto writer = index.get("meta", "writer");
    owner = writer.is_null() ? stringValue(marker, "initialWriter") : identifier(writer);
    if (!owner.empty()) owner = identifier(owner);
    std::set<std::string> commits;
    for (const auto& name : tree.children(journalPath)) {
        if (name.size() == 25 && name.ends_with(".json") &&
            std::all_of(name.begin(), name.begin() + 20, [](char c) { return c >= '0' && c <= '9'; })) commits.insert(join(journalPath, name));
    }
    require(generation >= 0 && static_cast<uint64_t>(generation) <= commits.size(), "硬盘提交记录不完整");
    if (marker.at("version") == 2) require(static_cast<uint64_t>(integer(marker.at("legacyGeneration"))) <= commits.size(), "旧版记录不完整");
    if (generation) require(identifier(readBatch(commitPath(generation)).at("id")) == head, "硬盘提交记录已更改");
    for (auto i = generation + 1; i <= static_cast<int64_t>(commits.size()); ++i) {
        auto batch = readBatch(commitPath(i));
        require(integer(batch.at("generation")) == i, "备份提交记录不连续");
        const auto incoming = exists(batch, "writer") ? identifier(batch.at("writer")) : "";
        const bool takeover = batch.value("takeover", false);
        if (batch.value("version", 1) == 2 && !takeover) require(incoming == owner, "接管记录与写入者不符");
        replay(batch, incoming == host && !takeover && !index.get("meta", "binding").is_null());
    }
    if (tree.entry(pendingPath)) {
        require(marker.at("version") == 2, "请先在 Mac 恢复未完成的 v1 事务");
        auto pending = readBatch(pendingPath);
        const auto g = integer(pending.at("generation"));
        if (g == generation + 1) {
            require(pending.value("takeover", false) || stringValue(pending, "writer") == owner, "恢复记录写入者不符");
            for (auto i = pending.at("edits").rbegin(); i != pending.at("edits").rend(); ++i) rollback(*i, pending.at("chunks"));
            recovered = true;
        } else require(g == generation && identifier(pending.at("id")) == head, "恢复记录顺序异常");
        tree.remove(pendingPath);
        tree.flushDirectory(journalPath);
    }
    clean();
}
void Repository::upgrade() {
    if (marker.at("version") == 2) return;
    require(!tree.entry(pendingPath), "请先在 Mac 恢复旧事务");
    Json next = {{"version", 2}, {"job", marker.at("job")}, {"format", marker.at("format")}, {"legacyGeneration", generation}};
    tree.writeDocument(markerPath, next.dump(), true);
    marker = std::move(next);
}
void Repository::claim() {
    auto next = batch();
    next["takeover"] = true;
    next["writer"] = host;
    commit(std::move(next));
}
Json Repository::batch() const {
    require(generation < INT64_MAX, "提交代次已满");
    auto result = Json{{"version", 2}, {"id", uuid()}, {"generation", generation + 1}, {"edits", Json::array()},
        {"chunks", Json::array()}, {"pruned", Json::array()}, {"retiredPacks", Json::array()}};
    if (!owner.empty()) result["writer"] = owner;
    return result;
}
void Repository::commit(Json next, const std::unordered_map<std::string, Patch>& patches, const std::function<void()>& validate,
                        bool align, const std::unordered_map<std::string, std::optional<Stamp>>& expected) {
    tree.check();
    const auto takeover = next.value("takeover", false);
    const auto& edits = next.at("edits");
    const auto archiveOnly = !edits.empty() && std::all_of(edits.begin(), edits.end(), [](const Json& item) {
        return item.at("method") == "archive";
    });
    require(marker.at("version") == 2 && (owner == host || takeover || archiveOnly), "请先接管此备份");
    require(integer(next.at("generation")) == generation + 1 && !tree.entry(pendingPath) &&
            !tree.entry(commitPath(generation + 1)), "备份记录已变化");
    if (generation) require(identifier(readBatch(commitPath(generation)).at("id")) == head, "备份提交已变化");
    if (validate) validate();
    tree.flushDirectory(stagePath);
    tree.writeDocument(pendingPath, envelope(next).dump());
    if (fault_) fault_(Interruption::prepared);
    for (auto& edit : next["edits"]) {
        const auto rel = edit.at("path").get<std::string>();
        auto found = expected.find(rel);
        if (found != expected.end()) {
            auto where = exists(edit, "from") ? edit.at("from").get<std::string>() : rel;
            auto actual = tree.entry(where);
            require(actual == found->second || (actual && found->second && actual->kind == Kind::directory &&
                found->second->kind == Kind::directory && actual->identity == found->second->identity),
                "提交前目标文件已变化");
        }
        apply(edit, patches);
        if (edit.at("method") != "record" && edit.at("method") != "archive") {
            if (tree.entry(parent(rel))) tree.flushDirectory(parent(rel));
            if (exists(edit, "from")) tree.flushDirectory(parent(edit.at("from").get<std::string>()));
        }
    }
    tree.flushDirectory(stagePath);
    if (fault_) fault_(Interruption::applied);
    tree.writeDocument(commitPath(generation + 1), envelope(next).dump());
    if (fault_) fault_(Interruption::committed);
    replay(next, align);
    tree.remove(pendingPath);
    tree.flushDirectory(journalPath);
}
void Repository::apply(Json& edit, const std::unordered_map<std::string, Patch>& patches) {
    const auto method = edit.at("method").get<std::string>();
    const auto rel = edit.at("path").get<std::string>();
    if (method == "record" || method == "archive") return;
    if (method == "install") {
        tree.rename(join(stagePath, identifier(edit.at("staging"))), rel, exists(edit, "before"));
    } else if (method == "patch") {
        const auto& patch = patches.at(rel);
        auto dest = tree.file(rel, File::Mode::write);
        std::optional<File> spool;
        if (!patch.blocks.empty()) spool.emplace(patch.spool, File::Mode::read);
        const auto size = integer(edit.at("next").at("source").at("size"));
        int64_t cursor = 0;
        bool first = true;
        for (auto block : patch.blocks) {
            auto offset = block * blockSize;
            auto bytes = spool->read(cursor, static_cast<size_t>(std::min(blockSize, size - offset)));
            dest.write(offset, bytes);
            cursor += static_cast<int64_t>(bytes.size());
            if (first && fault_) fault_(Interruption::firstBlock);
            first = false;
        }
        dest.resize(size);
        dest.flush();
        setMeta(tree, rel, edit.at("next").at("attributes"));
        dest.flush();
    } else if (method == "attributes") {
        setMeta(tree, rel, edit.at("next").at("attributes"));
    } else if (method == "remove") {
        tree.remove(rel, true);
    } else if (method == "move" || method == "caseMove") {
        auto from = edit.at("from").get<std::string>();
        if (method == "caseMove") {
            auto staging = join(stagePath, identifier(edit.at("staging")));
            tree.rename(from, staging);
            tree.rename(staging, rel);
        } else tree.rename(from, rel);
    }
    if (exists(edit, "next")) {
        if (auto s = tree.entry(rel)) edit["next"]["target"] = portableStamp(*s);
    }
}
void Repository::rollback(const Json& edit, const Json& additional) {
    const auto method = edit.at("method").get<std::string>();
    const auto rel = edit.at("path").get<std::string>();
    if (method == "record" || method == "archive") return;
    require(representable(rel), "此恢复路径在 Windows 无法表示");
    const auto current = tree.entry(rel);
    const auto next = edit.value("next", Json(nullptr));
    const auto after = [&] {
        return !next.is_null() && matches(tree, rel, next.at("source"), unbase64(next.at("hashes").get<std::string>()));
    };
    if (method == "move" || method == "caseMove") {
        const auto from = edit.at("from").get<std::string>();
        const auto staging = join(stagePath, identifier(edit.at("staging")));
        if (tree.entry(staging)) tree.rename(staging, from);
        else if (method == "caseMove" && current) {
            const auto names = tree.children(parent(rel));
            if (std::find(names.begin(), names.end(), name(rel)) != names.end() &&
                std::find(names.begin(), names.end(), name(from)) == names.end()) {
                require(after(), "移动后的文件已被修改");
                tree.rename(rel, staging);
                tree.rename(staging, from);
            }
        } else if (!tree.entry(from) && current) {
            require(after(), "移动后的文件已被修改");
            tree.rename(rel, from);
        }
        return;
    }
    if (method == "attributes") {
        if (current) {
            require(after(), "恢复属性时发现文件已更改");
            setMeta(tree, rel, edit.at("originalAttributes"));
        }
        return;
    }
    const auto saved = edit.value("archive", Json(nullptr));
    if (method == "patch") {
        require(!saved.is_null(), "缺少更新前的内容");
        if (!current) { publishRestored(*this, saved, additional, rel); return; }
        require(current->kind == Kind::regular, "恢复位置已被占用");
        const auto before = unbase64(saved.at("hashes").get<std::string>());
        const auto later = unbase64(next.at("hashes").get<std::string>());
        const auto previousSize = integer(saved.at("item").at("size"));
        const auto laterSize = integer(next.at("source").at("size"));
        auto out = tree.file(rel, File::Mode::write);
        require(current->size >= std::min(previousSize, laterSize) && current->size <= std::max(previousSize, laterSize),
                "中断的文件已被其他程序改写");
        for (int64_t offset = 0; offset < current->size; offset += blockSize) {
            auto hash = sha256(out.read(offset, static_cast<size_t>(std::min(blockSize, current->size - offset))));
            const auto i = static_cast<size_t>(offset / blockSize * 32);
            require((i < before.size() && hash == before.substr(i, 32)) || (i < later.size() && hash == later.substr(i, 32)),
                    "中断的文件包含未知内容，需手动检查");
        }
        std::set<int64_t> undo;
        for (const auto& item : edit.at("rollbackBlocks")) undo.insert(integer(item));
        if (laterSize < previousSize)
            for (auto i = laterSize / blockSize; i < static_cast<int64_t>(before.size() / 32); ++i) undo.insert(i);
        for (auto i : undo) {
            auto index = static_cast<size_t>(i * 32);
            if (index < before.size()) out.write(i * blockSize, chunk(before.substr(index, 32), additional));
        }
        out.resize(previousSize);
        setMeta(tree, rel, saved.at("attributes"));
        out.flush();
        return;
    }
    if (!saved.is_null()) {
        if (current && matches(tree, rel, versionStamp(saved), unbase64(saved.at("hashes").get<std::string>()))) return;
        require(!current || (method == "install" && after()), "恢复位置已被其他程序改写");
        publishRestored(*this, saved, additional, rel);
    } else if (method == "install" && current && !tree.entry(join(stagePath, identifier(edit.at("staging"))))) {
        require(after(), "安装中的文件已被改写");
        tree.remove(rel, true);
    }
    if (tree.entry(parent(rel))) tree.flushDirectory(parent(rel));
}
void Repository::replay(const Json& batch, bool align) {
    const auto gen = integer(batch.at("generation"));
    const auto id = identifier(batch.at("id"));
    const auto writer = exists(batch, "writer") ? identifier(batch.at("writer")) : owner;
    index.transaction([&] {
        for (const auto& loc : batch.at("chunks")) index.put("chunk", loc.at("hash").get<std::string>(), loc);
        auto erase = [&](std::string_view rel) {
            index.remove("file", rel);
            index.remove("folded", folded(rel));
            index.remove("observed", rel);
            if (align) index.remove("base", rel);
        };
        for (const auto& edit : batch.at("edits")) {
            const auto rel = edit.at("path").get<std::string>();
            if (exists(edit, "from")) erase(edit.at("from").get<std::string>());
            if (exists(edit, "next")) {
                index.put("file", rel, edit.at("next"));
                index.put("folded", folded(rel), rel);
                if (align) index.put("base", rel, edit.at("next"));
            } else if (edit.at("method") != "archive") erase(rel);
            if (exists(edit, "archive")) {
                auto v = edit.at("archive");
                v["item"]["date"] = encodeTime(eventTime(v["item"]["date"]));
                index.put("archive", identifier(v["item"]["id"]), v);
            }
            if (exists(edit, "activity")) {
                auto event = edit.at("activity");
                event["date"] = encodeTime(eventTime(event.at("date")));
                const auto digits = std::to_string(gen);
                index.put("activity", std::string(20 - digits.size(), '0') + digits + ":" + identifier(event.at("id")), event);
            }
        }
        if (!batch.at("edits").empty()) index.keepNewest("activity");
        for (const auto& version : batch.at("pruned")) index.remove("archive", identifier(version));
        if (!batch.at("retiredPacks").empty()) {
            std::set<std::string> retired;
            for (const auto& pack : batch.at("retiredPacks")) retired.insert(identifier(pack));
            for (const auto& [hash, loc] : index.all("chunk")) if (retired.contains(identifier(loc.at("pack")))) index.remove("chunk", hash);
        }
        index.put("meta", "generation", gen);
        index.put("meta", "head", id);
        if (!writer.empty()) index.put("meta", "writer", writer);
    });
    generation = gen;
    head = id;
    owner = writer;
}
void Repository::bind(std::string_view identity) {
    auto files = index.all("file");
    index.transaction([&] {
        index.clear("base");
        index.clear("observed");
        for (const auto& [path, record] : files) index.put("base", path, record);
        index.put("meta", "binding", std::string(identity));
    });
}
Bytes Repository::chunk(std::string_view hash, const Json& additional) {
    auto key = base64(hash);
    Json location;
    for (const auto& candidate : additional) {
        if (candidate.at("hash") == key) { location = candidate; break; }
    }
    if (location.is_null()) location = index.get("chunk", key);
    require(!location.is_null(), "历史数据块缺失");
    const auto id = identifier(location.at("pack"));
    auto file = tree.file(join(packPath, id));
    const auto size = integer(location.at("length")), offset = integer(location.at("offset"));
    require(size > 0 && size <= blockSize && offset >= 0 && offset <= INT64_MAX - size, "历史块位置无效");
    auto bytes = file.read(offset, static_cast<size_t>(size));
    require(sha256(bytes) == hash, "历史数据块校验失败");
    return bytes;
}
void Repository::restore(const Json& version, const Tree& out, std::string_view rel, const Json& additional) {
    const auto kind = version.at("kind").get<std::string>();
    if (kind == "directory") out.mkdir(rel);
    else if (kind == "regular") {
        auto file = out.file(rel, File::Mode::create);
        const auto hashes = unbase64(version.at("hashes").get<std::string>());
        int64_t offset = 0;
        for (size_t i = 0; i < hashes.size(); i += 32) {
            auto data = chunk(std::string_view(hashes).substr(i, 32), additional);
            file.write(offset, data);
            offset += static_cast<int64_t>(data.size());
        }
        require(offset == integer(version.at("item").at("size")), "历史文件大小校验失败");
        file.flush();
    } else if (kind == "symlink" && version.at("attributes").value("windowsLink", false)) {
        out.createLink(rel, unbase64(version.at("link").get<std::string>()),
                       version.at("attributes").value("windowsLinkDirectory", false));
        return;
    } else throw std::runtime_error("此链接需在原平台恢复");
    setMeta(out, rel, version.at("attributes"), out.root() != tree.root());
}
void Repository::copyCurrent(const Json& record, const Tree& out, std::string_view rel) {
    const auto kind = record.at("source").at("kind").get<std::string>();
    if (kind == "directory") out.mkdir(rel);
    else if (kind == "regular") {
        auto file = out.file(rel, File::Mode::create);
        copyChecked(tree.file(record.at("path").get<std::string>()), file, integer(record.at("source").at("size")),
                    unbase64(record.at("hashes").get<std::string>()));
    } else if (kind == "symlink" && record.at("attributes").value("windowsLink", false)) {
        out.createLink(rel, unbase64(record.at("link").get<std::string>()),
                       record.at("attributes").value("windowsLinkDirectory", false));
        return;
    } else throw std::runtime_error("此链接需在原平台恢复");
    setMeta(out, rel, record.at("attributes"), true);
}
void Repository::clean() {
    for (const auto& item : tree.children(stagePath)) {
        if (item.size() == 36) {
            try { identifier(item); } catch (...) { continue; }
            tree.removeOwned(join(stagePath, item));
        }
    }
    for (const auto& item : tree.children(journalPath)) if (item.starts_with(".write-")) tree.remove(join(journalPath, item));
    std::set<std::string> used;
    for (const auto& [_, item] : index.all("chunk")) used.insert(identifier(item.at("pack")));
    for (const auto& item : tree.children(packPath)) {
        std::string id;
        try { id = identifier(item); } catch (...) { continue; }
        if (!used.contains(id)) tree.remove(join(packPath, item));
    }
}
void Repository::prune(Time time) {
    if (owner != host || marker.at("version") != 2) return;
    auto next = batch();
    auto versions = index.all("archive");
    std::set<std::string> live;
    for (const auto& [id, saved] : versions) {
        if (eventTime(saved.at("item").at("date")).seconds < time.seconds - 30 * 86400) next["pruned"].push_back(id);
        else {
            auto hashes = unbase64(saved.at("hashes").get<std::string>());
            for (size_t i = 0; i < hashes.size(); i += 32) live.insert(base64(std::string_view(hashes).substr(i, 32)));
        }
    }
    std::map<std::string, std::vector<Json>> packMembers;
    for (const auto& [hash, loc] : index.all("chunk")) {
        auto& parts = packMembers[identifier(loc.at("pack"))];
        if (live.contains(hash)) parts.push_back(loc);
    }
    for (const auto& [pack, members] : packMembers) if (members.empty()) next["retiredPacks"].push_back(pack);
    if (!next["pruned"].empty() || !next["retiredPacks"].empty()) commit(next);
    for (const auto& [pack, members] : packMembers) {
        if (members.empty()) continue;
        auto stamp = tree.entry(join(packPath, pack));
        int64_t retained = 0;
        for (const auto& loc : members) retained += integer(loc.at("length"));
        if (!stamp || stamp->size < 1024 * 1024 || retained >= stamp->size / 2) continue;
        auto compact = batch();
        PackWriter writer(*this, identifier(compact.at("id")));
        for (const auto& loc : members) {
            const auto hash = unbase64(loc.at("hash").get<std::string>());
            // Write directly to the replacement pack, independent of deduplication.
            auto data = chunk(hash);
            writer.add(hash, data);
        }
        compact["chunks"] = writer.finish();
        compact["retiredPacks"].push_back(pack);
        commit(compact);
        break;
    }
    if (fault_) fault_(Interruption::pruning);
    clean();
}

PackWriter::PackWriter(Repository& repo, std::string id) : repo_(repo), id_(std::move(id)) {}
bool PackWriter::contains(std::string_view hash) {
    auto key = base64(hash);
    return locations_.contains(key) || !repo_.index.get("chunk", key).is_null();
}
void PackWriter::add(std::string_view hash, std::string_view bytes) {
    auto key = base64(hash);
    if (locations_.contains(key)) return;
    if (!file_) file_.emplace(repo_.tree.file(join(packPath, id_), File::Mode::create));
    file_->write(length_, bytes);
    locations_[key] = Json{{"hash", key}, {"pack", id_}, {"offset", length_}, {"length", bytes.size()}};
    length_ += static_cast<int64_t>(bytes.size());
}
Json PackWriter::saveFile(const Tree& tree, std::string_view rel, const Stamp& stamp, std::string_view known, int64_t& bytesRead) {
    auto file = tree.file(rel);
    require(file.stamp() == stamp, "归档前文件已更改");
    Bytes hashes;
    for (int64_t offset = 0; offset < stamp.size;) {
        const auto length = static_cast<size_t>(std::min(blockSize, stamp.size - offset));
        const auto index = static_cast<size_t>(offset / blockSize * 32);
        auto expected = index < known.size() ? known.substr(index, 32) : std::string_view{};
        if (!expected.empty() && contains(expected)) hashes += expected;
        else {
            auto data = file.read(offset, length);
            bytesRead += static_cast<int64_t>(data.size());
            auto hash = sha256(data);
            require(expected.empty() || expected == hash, "归档时发现目标内容已更改");
            if (!contains(hash)) add(hash, data);
            hashes += hash;
        }
        offset += static_cast<int64_t>(length);
    }
    require(file.stamp() == stamp && tree.entry(rel) == stamp, "归档时文件已变化");
    return base64(hashes);
}
Json PackWriter::finish() {
    if (file_) {
        file_->flush();
        file_.reset();
        repo_.tree.flushDirectory(packPath);
    }
    auto result = Json::array();
    for (const auto& [_, loc] : locations_) result.push_back(loc);
    return result;
}
}
