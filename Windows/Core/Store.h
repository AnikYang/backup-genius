#pragma once

#include "NativeFiles.h"
#include <map>
#include <nlohmann/json.hpp>
#include <unordered_map>

struct sqlite3;
struct sqlite3_stmt;

namespace bg {
using Json = nlohmann::json;
using Records = std::map<std::string, Json>;
const std::string markerPath = ".backup-genius/job.json";
const std::string journalPath = ".backup-genius/journal";
const std::string pendingPath = ".backup-genius/journal/pending.json";
const std::string packPath = ".backup-genius/packs";
const std::string stagePath = ".backup-genius/stage";
const std::string versionsPath = ".backup-genius/versions";

std::string identifier(const Json&);
int64_t integer(const Json&);
Json encodeTime(Time);
Time decodeTime(const Json&);
Time eventTime(const Json&);
std::string kindName(Kind);
Json portableStamp(const Stamp&);
Json observedStamp(const Stamp&);
Json attributes(const Stamp&, const Json& inherited = nullptr);
Json recipe(std::string path, const Stamp&, std::string_view hashes, const Json& inherited = nullptr);
Json activity(std::string kind, std::string path, int64_t bytes = 0, std::string detail = {});
Json archiveVersion(const Json& record, std::string reason, std::string id = {});
bool sameContent(const Json& left, const Json& right);
bool exists(const Json& value, std::string_view key);

class Index {
public:
    explicit Index(const fs::path&);
    ~Index();
    Index(const Index&) = delete;
    Json get(std::string_view bucket, std::string_view key);
    Records all(std::string_view bucket);
    Records below(std::string_view bucket, std::string_view path);
    int64_t count(std::string_view bucket);
    void put(std::string_view bucket, std::string_view key, const Json&);
    void remove(std::string_view bucket, std::string_view key);
    void clear(std::string_view bucket);
    void keepNewest(std::string_view bucket);
    void transaction(const std::function<void()>&);
private:
    void sql(const char*);
    void statement(const char*, const std::vector<std::string_view>&, const std::function<void(sqlite3_stmt*)>&);
    sqlite3* db_{};
    std::unordered_map<std::string, sqlite3_stmt*> statements_;
};

struct Patch {
    fs::path spool;
    std::vector<int64_t> blocks;
    size_t window{IOProfile::window(StorageMedium::unknown)};
    std::vector<std::pair<int64_t, size_t>> writes(int64_t size, bool splitFirst = false) const;
};
enum class Interruption { prepared, firstBlock, applied, committed, pruning, pointPrepared, pointCommitted, pointPruning };
using Fault = std::function<void(Interruption)>;

class Repository {
public:
    static Json create(const Tree&, std::string format, std::string writer, bool organized = false);
    static Tree member(const Tree& disk, std::string_view folder, std::string_view job);
    static void initializeMember(const Tree& disk, std::string_view folder, const Json& marker);
    static Json readMarker(const Tree&);
    Repository(Tree target, Index&, std::string writer, Fault = {});
    ~Repository();
    Repository(const Repository&) = delete;
    void open();
    void upgrade();
    void claim();
    Json batch() const;
    void commit(Json batch, const std::unordered_map<std::string, Patch>& patches = {},
                const std::function<void()>& validate = {}, bool align = false,
                const std::unordered_map<std::string, std::optional<Stamp>>& expected = {},
                const std::function<void(size_t)>& onWrite = {});
    void prune(Time);
    void bind(std::string_view sourceIdentity);
    Bytes chunk(std::string_view hash, const Json& additional = Json::array());
    void restore(const Json& version, const Tree& destination, std::string_view path, const Json& additional = Json::array());
    void copyCurrent(const Json& record, const Tree& destination, std::string_view path);

    Tree tree;
    Index& index;
    Json marker;
    const std::string host;
    std::string owner;
    int64_t generation{};
    std::string head;
    IOProfile ioProfile;
    bool recovered{};
private:
    static Tree locate(const Tree&);
    Json readBatch(std::string_view path);
    void replay(const Json&, bool align);
    void apply(Json&, const std::unordered_map<std::string, Patch>&, const std::function<void(size_t)>&);
    void rollback(const Json& edit, const Json& additional);
    void clean();
    std::string commitPath(int64_t generation) const;
    FileLease lease_;
    Fault fault_;
};

class PackWriter {
public:
    PackWriter(Repository&, std::string id, std::function<void(size_t)> onWrite = {});
    void add(std::string_view hash, std::string_view bytes);
    bool contains(std::string_view hash);
    Json saveFile(const Tree&, std::string_view path, const Stamp&, std::string_view known, int64_t& bytesRead,
                  const std::function<void(size_t)>& onRead = {});
    Json finish();
    int64_t bytes() const { return length_; }
private:
    void flushBuffer();
    Repository& repo_;
    std::string id_;
    std::optional<File> file_;
    std::map<std::string, Json> locations_;
    int64_t length_{};
    Bytes buffered_;
    int64_t bufferedOffset_{};
    std::function<void(size_t)> onWrite_;
};
}
