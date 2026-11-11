#pragma once

#include "Store.h"

namespace bg {
inline constexpr std::string_view backupRoot = "BackupGenius";

struct FolderMapping {
    std::string id, job, folder;
    bool enabled{true};
    bool operator==(const FolderMapping&) const = default;
};

struct BackupSet {
    std::string id, format;
    int64_t revision{};
    std::vector<FolderMapping> mappings;
    bool operator==(const BackupSet&) const = default;
};

struct SetMove { std::string from, to, job; };
struct SetTransition {
    int64_t base;
    BackupSet next;
    std::vector<Json> additions;
    std::vector<SetMove> moves;
};
enum class SetInterruption { prepared, relocated, published };

Json setDocument(const BackupSet&);
BackupSet readSet(const Json&);

class BackupSetStore {
public:
    explicit BackupSetStore(Volume, std::function<void(SetInterruption)> = {});
    static std::optional<BackupSet> read(const Tree&, std::string_view format);
    std::optional<BackupSet> recover();
    void apply(const SetTransition&);

    Tree disk;
    Volume volume;
private:
    void finish(const SetTransition&);
    void checkRootSlot(bool existing);
    void checkTargetSlot(std::string_view);
    void relocate(const SetMove&, int64_t revision);
    FileLease lease_;
    std::function<void(SetInterruption)> fault_;
};
}
