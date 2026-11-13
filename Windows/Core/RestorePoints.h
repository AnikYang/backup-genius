#pragma once
#include "Store.h"
#include <set>

namespace bg {
class RestorePointStore {
public:
    explicit RestorePointStore(Repository&, Fault = {});
    Json list(Time at = now()) const;
    Json capture(const std::function<void(size_t)>& read = {}, const std::function<void(size_t)>& write = {}, const std::function<void()>& checkCancellation = {});
    void restore(std::string_view id, const Tree&, std::string_view root);
    void prune(Time at = now());
private:
    void loadContents();
    bool contentsLoaded_{};
    Json read(std::string_view) const;
    void write(std::string_view, const Json&) const;
    void apply(const Json&, Records&, bool collect = true, const std::function<void(const Json&)>& visit = {});
    Repository& repo_;
    Fault fault_;
    std::vector<Json> points_;
    Records entries_, chunks_;
    std::set<std::string> committedPacks_, committedSegments_;
};
}
