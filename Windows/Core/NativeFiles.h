#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace bg {
namespace fs = std::filesystem;
using Bytes = std::string;
constexpr int64_t blockSize = 65536;
constexpr std::string_view control = ".backup-genius";
constexpr std::string_view identityFile = ".backup-genius.json";
constexpr std::string_view storageFolder = ".backup-genius-data";

struct Time {
    int64_t seconds{};
    int32_t nanoseconds{};
    bool operator==(const Time&) const = default;
};

enum class Kind { regular, directory, link, unsupported };
struct Stamp {
    Kind kind{};
    int64_t size{};
    Time modified, created, changed;
    uint32_t attributes{};
    std::string identity;
    bool operator==(const Stamp&) const = default;
};

fs::path path(std::string_view value);
std::string utf8(const fs::path& value);
std::string folded(std::string_view value);
std::string parent(std::string_view value);
std::string name(std::string_view value);
std::string join(std::string_view base, std::string_view child);
bool inside(std::string_view value, std::string_view base);
bool backupControl(std::string_view value);
bool validPath(std::string_view value, bool user = true);
bool representable(std::string_view value);
std::string uuid();
Time now();
Bytes sha256(std::string_view data);
Bytes base64(std::string_view data);
Bytes unbase64(std::string_view data);

class File {
public:
    enum class Mode { read, write, create };
    File(const fs::path&, Mode);
    ~File();
    File(File&&) noexcept;
    File& operator=(File&&) noexcept;
    File(const File&) = delete;
    Stamp stamp() const;
    Bytes read(int64_t offset, size_t count) const;
    void write(int64_t offset, std::string_view data);
    void resize(int64_t size);
    void flush();
    void times(Time modified, Time created);
private:
    intptr_t handle_{-1};
};

class Tree {
public:
    explicit Tree(fs::path root);
    Tree withControl(const fs::path& storage) const;
    bool separateControl() const { return static_cast<bool>(control_); }
    const fs::path& root() const { return root_; }
    const Stamp& identity() const { return identity_; }
    void check() const;
    std::optional<Stamp> entry(std::string_view relative) const;
    fs::path checked(std::string_view relative) const;
    File file(std::string_view relative, File::Mode mode = File::Mode::read) const;
    std::vector<std::string> children(std::string_view relative = {}) const;
    void walk(std::string_view relative, const std::function<void(const std::string&, const Stamp&)>&,
              bool skipControl = true) const;
    void mkdir(std::string_view relative) const;
    void parents(std::string_view relative) const;
    void rename(std::string_view from, std::string_view to, bool replace = false) const;
    void remove(std::string_view relative, bool keepNonEmpty = false) const;
    void removeOwned(std::string_view relative) const;
    void createLink(std::string_view relative, std::string_view target, bool directory) const;
    Bytes readDocument(std::string_view relative) const;
    void writeDocument(std::string_view relative, std::string_view data, bool replace = false) const;
    void metadata(std::string_view relative, Time modified, Time created, uint32_t attributes, bool readOnly = false) const;
    void flushDirectory(std::string_view relative = {}) const;
    void hide(std::string_view relative) const;
private:
    std::pair<const Tree*, std::string_view> route(std::string_view relative) const;
    fs::path root_;
    Stamp identity_;
    std::shared_ptr<const Tree> control_;
};

struct Volume {
    fs::path mount;
    std::string id, label, format;
    uint64_t free{}, total{};
    bool external{}, solidState{};
};
Volume inspect(const fs::path&);
std::optional<fs::path> findVolume(std::string_view id);
void eject(const Volume&);
Bytes hashFile(const File&, int64_t size, int64_t* readBytes = nullptr);
void copyChecked(const File&, File&, int64_t size, std::string_view hashes);
}
