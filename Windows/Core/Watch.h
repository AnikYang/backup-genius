#pragma once

#include "NativeFiles.h"
#include <map>
#include <memory>

namespace bg {
constexpr uint32_t nameChange = 1;
constexpr uint32_t contentChange = 2;
struct Changes {
    std::map<std::string, uint32_t> paths;
    bool full{};
};
struct Cursor {
    uint64_t journal{};
    int64_t next{};
};
std::optional<Cursor> currentCursor(const fs::path& root);
std::optional<Changes> changesSince(const fs::path& root, Cursor from, Cursor to);

class DirectoryWatch {
public:
    explicit DirectoryWatch(const fs::path& root);
    ~DirectoryWatch();
    Changes take();
    bool alive() const;
    std::optional<fs::path> location() const;
private:
    struct State;
    std::unique_ptr<State> state_;
};
}
