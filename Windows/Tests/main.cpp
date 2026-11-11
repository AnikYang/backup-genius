#include "../Core/Coordinator.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#ifdef _WIN32
#include <windows.h>
#endif

using namespace bg;
namespace {
void expect(bool ok, std::string_view description) {
    if (!ok) throw std::runtime_error(std::string(description));
}
void write(const Tree& tree, std::string_view rel, std::string_view data) {
    tree.parents(rel);
    auto file = tree.file(rel, tree.entry(rel) ? File::Mode::write : File::Mode::create);
    file.write(0, data);
    file.resize(static_cast<int64_t>(data.size()));
    file.flush();
}
Bytes read(const Tree& tree, std::string_view rel) {
    auto file = tree.file(rel);
    return file.read(0, static_cast<size_t>(file.stamp().size));
}
struct Fixture {
    fs::path root, source, target, state, restore;
    Fixture(const fs::path& volume = {}) {
        auto temp = fs::canonical(fs::temp_directory_path());
        root = temp / ("bg-test-" + uuid());
        fs::create_directory(root);
        source = root / "source";
        target = (volume.empty() ? root : volume) / ("bg-target-" + uuid());
        state = root / "state";
        restore = root / "restore";
        for (const auto& p : {source, target, state, restore}) fs::create_directory(p);
    }
    ~Fixture() {
        std::error_code error;
        fs::remove_all(target, error);
        fs::remove_all(root, error);
    }
};

void incremental(const fs::path& volume) {
    Fixture f(volume);
    const Tree source(f.source), disk(f.target);
    SyncEngine engine(f.state, {}, true);
    Bytes data(3 * blockSize, 'a');
    write(source, "images/payload.bin", data);
    write(source, "images/small.txt", "one");
    write(source, ".hidden", "hidden");
    engine.configure(f.source, f.target, false);
    auto first = engine.sync();
    expect(first.state == SyncState::upToDate && first.latestWritten == data.size() + 9, "first copy");
    expect(read(disk, "images/payload.bin") == data && read(disk, ".hidden") == "hidden", "initial data");
    auto idle = engine.sync();
    expect(idle.sourceRead == 0 && idle.targetRead == 0 && idle.latestWritten == 0 && idle.historyWritten == 0, "unchanged I/O");
    auto before = source.entry("images/payload.bin").value();
    data[blockSize + 19] = 'b';
    write(source, "images/payload.bin", data);
    source.metadata("images/payload.bin", before.modified, before.created, before.attributes);
    engine.recordChanges({{{"images/payload.bin", contentChange}}});
    auto patch = engine.sync();
    expect(patch.state == SyncState::upToDate && patch.latestWritten == blockSize && patch.historyWritten > 0, "one block delta");
    expect(read(disk, "images/payload.bin") == data, "patched content");
    auto versions = engine.history();
    expect(versions.size() == 1, "history count");
    auto restored = Tree(engine.restore(f.restore, versions[0].at("id").get<std::string>()));
    expect(read(restored, "payload.bin") == Bytes(3 * blockSize, 'a'), "historical contents");

    source.rename("images/small.txt", "images/temporary-name");
    source.rename("images/temporary-name", "images/Small.txt");
    engine.recordChanges({{{"images/small.txt", nameChange}, {"images/Small.txt", nameChange}}});
    auto moved = engine.sync();
    expect(moved.latestWritten == 0 && read(disk, "images/Small.txt") == "one", "case-only move");

    data.resize(2 * blockSize, 'c');
    write(source, "images/payload.bin", data);
    engine.recordChanges({{{"images/payload.bin", contentChange}}});
    expect(engine.sync().latestWritten == 0 && read(disk, "images/payload.bin") == data, "truncate");
    data += Bytes(2 * blockSize + 19, 'd');
    write(source, "images/payload.bin", data);
    engine.recordChanges({{{"images/payload.bin", contentChange}}});
    expect(engine.sync().latestWritten == 2 * blockSize + 19 && read(disk, "images/payload.bin") == data, "grow");
    write(disk, "outside.txt", "unmanaged");
    write(disk, "images/Small.txt", "foreign");
    engine.recordChanges({{}, true}, true);
    const auto external = engine.sync();
    expect(external.unmanaged >= 1, "unmanaged content reported");
    expect(read(disk, "outside.txt") == "unmanaged", "unmanaged content preserved");
    expect(read(disk, "images/Small.txt") == "one", "external edit reconciled: " + engine.activities().dump());
    source.remove("images/Small.txt");
    engine.recordChanges({{{"images/Small.txt", nameChange}}});
    engine.sync();
    expect(!disk.entry("images/Small.txt"), "deleted from latest copy");
}
void interrupted(const fs::path& volume, Interruption at) {
    Fixture f(volume);
    const Tree source(f.source), disk(f.target);
    Bytes data(2 * blockSize, 'a');
    write(source, "payload.bin", data);
    bool armed = false, triggered = false;
    {
        SyncEngine engine(f.state, {}, true, [&](Interruption step) {
            if (armed && step == at) { triggered = true; throw std::runtime_error("injected interruption"); }
        });
        engine.configure(f.source, f.target, false);
        engine.sync();
        armed = true;
        data.front() = 'b';
        write(source, "payload.bin", data);
        engine.recordChanges({{{"payload.bin", contentChange}}});
        try { engine.sync(); } catch (const std::exception&) { if (!triggered) throw; }
        expect(triggered && disk.entry(pendingPath).has_value(), "durable prepare record");
    }
    {
        SyncEngine other(f.root / "other", {}, true);
        other.openExisting(f.target);
        expect(!disk.entry(pendingPath), "other installation recovers pending");
        expect(read(disk, "payload.bin").front() == (at == Interruption::committed ? 'b' : 'a'), "commit or rollback contents");
    }
    SyncEngine restarted(f.state, {}, true);
    restarted.start();
    auto finished = restarted.sync();
    expect(finished.state == SyncState::upToDate && read(disk, "payload.bin") == data, "restart continues");
}
void ownership(const fs::path& volume) {
    Fixture f(volume);
    auto otherFolder = f.root / "source2";
    fs::create_directory(otherFolder);
    Tree a(f.source), b(otherFolder), disk(f.target);
    write(a, "payload.bin", "baseline");
    write(a, "receive.txt", "first");
    {
        SyncEngine first(f.state, {}, true);
        first.configure(f.source, f.target, false);
        first.sync();
    }
    {
        SyncEngine other(f.root / "other", {}, true);
        other.openExisting(f.target);
        auto preview = other.previewTakeover(otherFolder);
        other.confirmTakeover(preview.id, {});
        expect(read(b, "payload.bin") == "baseline", "empty source initialized");
        write(b, "payload.bin", "remote");
        write(b, "receive.txt", "second");
        other.sync();
    }
    write(a, "payload.bin", "local");
    SyncEngine first(f.state, {}, true);
    first.start();
    expect(first.sync().state == SyncState::takeoverRequired, "old writer fenced");
    auto preview = first.previewTakeover(f.source);
    expect(std::any_of(preview.changes.begin(), preview.changes.end(), [](const auto& change) {
        return change.path == "payload.bin" && change.kind == AlignmentKind::conflict;
    }), "three-way conflict");
    first.confirmTakeover(preview.id, {{"payload.bin", AlignmentChoice::both}});
    first.sync();
    expect(read(a, "receive.txt") == "second" && read(a, "payload.bin") == "remote", "aligned source");
    bool found = false;
    for (const auto& item : a.children()) {
        if (item.starts_with("Backup Genius conflict")) {
            expect(read(a, item) == "local" && read(disk, item) == "local", "kept both versions");
            found = true;
        }
    }
    expect(found, "conflict copy");
}
void pruning(const fs::path& volume) {
    Fixture f(volume);
    const Tree source(f.source), disk(f.target);
    write(source, "payload", "old");
    std::string id;
    {
        SyncEngine engine(f.state, {}, true);
        engine.configure(f.source, f.target, false);
        engine.sync();
        write(source, "payload", "new");
        engine.recordChanges({{{"payload", contentChange}}});
        engine.sync();
        expect(engine.history().size() == 1, "history before expiry");
        id = engine.presentation().job.id;
    }
    {
        Index settings(f.state / "settings.sqlite"), cache(f.state / (id + ".sqlite"));
        bool interrupted = false;
        Repository repo(disk, cache, identifier(settings.get("settings", "host")), [&](Interruption point) {
            if (point == Interruption::pruning) { interrupted = true; throw std::runtime_error("interrupted cleanup"); }
        });
        repo.open();
        try { repo.prune({now().seconds + 31 * 86400, 0}); }
        catch (...) { if (!interrupted) throw; }
        expect(interrupted && cache.count("archive") == 0 && read(disk, "payload") == "new", "prune commit precedes pack deletion");
    }
    SyncEngine reopened(f.root / "reopened", {}, true);
    reopened.openExisting(f.target);
    expect(reopened.history().empty() && read(disk, "payload") == "new", "interrupted prune replay");
}
#ifdef _WIN32
void liveEvents(const fs::path& volume) {
    Fixture f(volume);
    Tree source(f.source), disk(f.target);
    SyncEngine engine(f.state, {}, true);
    write(source, "file.txt", "one");
    engine.configure(f.source, f.target, true);
    engine.sync();
    const auto before = source.entry("file.txt").value();
    write(source, "file.txt", "two");
    source.metadata("file.txt", before.modified, before.created, before.attributes);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < deadline) {
        engine.poll();
        if (read(disk, "file.txt") == "two") return;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    throw std::runtime_error("ReadDirectoryChangesW missed same-size edit");
}
#endif
void safety(const fs::path& volume) {
    expect(!validPath("../escape") && !validPath(".backup-genius/job.json") &&
        !representable("folder/LPT¹.txt") && !representable("file:stream") && !representable("trailing."), "path rules");
    expect(integer(Json::parse("9007199254740993")) == 9007199254740993LL, "lossless integers");
    expect(decodeTime(Json::parse(R"({"seconds":1700000000,"nanoseconds":123456789})")).nanoseconds == 123456789,
        "lossless file time");
    Fixture f(volume);
    Tree source(f.source), disk(f.target);
    write(source, "file", "original");
    {
        SyncEngine engine(f.state, {}, true);
        engine.configure(f.source, f.target, false);
        engine.sync();
        bool locked = false;
        try { SyncEngine duplicate(f.root / "another", {}, true); duplicate.openExisting(f.target); }
        catch (...) { locked = true; }
        expect(locked, "exclusive disk lease");
        fs::rename(f.source, f.root / "source-moved");
        bool failed = false;
        try { engine.sync(); } catch (...) { failed = true; }
        expect(failed && read(disk, "file") == "original", "missing source preserves latest");
    }
    auto entries = disk.children(journalPath);
    auto found = std::find_if(entries.begin(), entries.end(), [](auto& value) {
        return value.size() == 25 && value.ends_with(".json") && value.front() == '0';
    });
    expect(found != entries.end(), "expected a committed journal file");
    const auto& entry = *found;
    auto stored = Json::parse(disk.readDocument(join(journalPath, entry)));
    stored["checksum"] = base64(Bytes(32, 'x'));
    disk.writeDocument(join(journalPath, entry), stored.dump(), true);
    bool rejected = false;
    try { SyncEngine engine(f.root / "clean", {}, true); engine.openExisting(f.target); }
    catch (...) { rejected = true; }
    expect(rejected && read(disk, "file") == "original", "corrupt journal fails closed");
}

void macOnlyNames(const fs::path& volume) {
    Fixture f(volume);
    const Tree disk(f.target);
    const auto host = uuid();
    const std::string foreign = "review:notes?.txt";
    const auto foreignRecord = recipe(foreign, Stamp{.kind = Kind::regular}, {});
    Repository::create(disk, "exfat", host);
    {
        Index cache(f.root / "first.sqlite");
        Repository repo(disk, cache, host);
        repo.open();
        auto batch = repo.batch();
        batch["edits"].push_back({{"method", "record"}, {"path", foreign}, {"next", foreignRecord},
                                  {"rollbackBlocks", Json::array()}});
        repo.commit(batch);
    }
    {
        Index cache(f.root / "second.sqlite");
        Repository repo(disk, cache, uuid());
        repo.open();
        expect(cache.get("file", foreign) == foreignRecord, "replay retains a Mac-only name");
        write(disk, "portable.txt", "already installed");
        auto pending = repo.batch();
        const auto ordinary = recipe("portable.txt", disk.entry("portable.txt").value(), sha256("already installed"));
        for (const auto& record : {foreignRecord, ordinary}) {
            pending["edits"].push_back({{"method", "install"}, {"path", record.at("path")}, {"next", record},
                                        {"staging", uuid()}, {"rollbackBlocks", Json::array()}});
        }
        const auto body = pending.dump();
        const Json envelope = {{"body", base64(body)}, {"checksum", base64(sha256(body))}};
        disk.writeDocument(pendingPath, envelope.dump());
    }
    bool deferred = false;
    try { SyncEngine engine(f.root / "reopen", {}, true); engine.openExisting(f.target); }
    catch (const std::exception& error) { deferred = std::string_view(error.what()).find("Mac") != std::string_view::npos; }
    expect(deferred && disk.entry(pendingPath).has_value(), "Mac-only pending edit requires the Mac recovery path");
    expect(read(disk, "portable.txt") == "already installed", "defer before rolling back any portable edits");
}

void organizedRepository(const fs::path& volume) {
    if (volume.empty()) return;
    Fixture f(volume);
    const Tree disk(f.target), source(f.source);
    const auto marker = Repository::create(disk, "exfat", uuid(), true);
    expect(disk.children() == std::vector<std::string>{std::string(identityFile)}, "backup root only has the identification file");
#ifdef _WIN32
    expect(disk.entry(identityFile)->attributes & FILE_ATTRIBUTE_HIDDEN, "identification file is hidden in Explorer");
#endif
    const Tree mount(inspect(f.target).mount);
    expect(mount.entry(join(storageFolder, identifier(marker.at("job")))).has_value(), "store is beside the backup folder");
    SyncEngine engine(f.state, {}, true);
    engine.openExisting(f.target);
    auto preview = engine.previewTakeover(f.source);
    engine.confirmTakeover(preview.id, {});
    write(source, "file.txt", "first");
    engine.recordChanges({{{"file.txt", nameChange}}});
    expect(engine.sync().state == SyncState::upToDate && read(disk, "file.txt") == "first", "publish files from external staging");
    write(source, "file.txt", "next");
    engine.recordChanges({{{"file.txt", contentChange}}});
    expect(engine.sync().state == SyncState::upToDate && read(disk, "file.txt") == "next", "incremental update with external records");
    const auto versions = engine.history();
    expect(versions.size() == 1, "history recorded outside the folder");
    const Tree restored(engine.restore(f.restore, versions[0].at("id").get<std::string>()));
    expect(read(restored, "file.txt") == "first", "restore from external history");
}

void collectionRecovery(const fs::path& volume) {
    for (auto point : {SetInterruption::prepared, SetInterruption::relocated, SetInterruption::published}) {
        Fixture f(volume);
        auto info = inspect(f.target);
        info.mount = f.target;
        info.format = "exfat";
        const auto job = uuid(), host = uuid();
        BackupSet set{uuid(), "exfat", 1, {{uuid(), job, "Projects", true}}};
        std::optional<SetInterruption> fault;
        {
            BackupSetStore store(info, [&](auto at) {
                if (fault == at) { fault.reset(); throw std::runtime_error("interrupted set change"); }
            });
            Json marker = {{"version", 2}, {"job", job}, {"format", "exfat"}, {"initialWriter", host}, {"legacyGeneration", 0}};
            store.apply({0, set, {marker}, {}});
            write(store.disk, "BackupGenius/Projects/file", "preserved");
            set.revision = 2;
            set.mappings[0].folder = "Work/Projects";
            fault = point;
            bool stopped = false;
            try { store.apply({1, set, {}, {{"Projects", "Work/Projects", job}}}); }
            catch (...) { stopped = true; }
            expect(stopped, "set interruption must fire");
        }
        BackupSetStore recovered(info);
        expect(recovered.recover() == set && recovered.recover() == set, "set recovery is repeatable");
        expect(read(recovered.disk, "BackupGenius/Work/Projects/file") == "preserved", "relocation preserves the latest bytes");
        expect(!recovered.disk.entry("BackupGenius/Work/Projects/.backup-genius.json"), "relocation witness is removed");
    }
}

void collections(const fs::path& volume) {
    if (volume.empty() || inspect(volume).format != "exfat") return;
    Fixture f;
    const auto work = f.source / "Work" / "Projects", personal = f.source / "Personal" / "Projects";
    fs::create_directories(work);
    fs::create_directories(personal);
    write(Tree(work), "file.txt", "first");
    write(Tree(personal), "file.txt", "personal");
    std::set<std::string> jobs;
    struct Cleanup {
        fs::path volume;
        std::set<std::string>& jobs;
        ~Cleanup() {
            std::error_code error;
            fs::remove_all(volume / path(backupRoot), error);
            fs::remove_all(volume / path(join(storageFolder, "set")), error);
            for (const auto& job : jobs) fs::remove_all(volume / path(join(storageFolder, job)), error);
        }
    } cleanup{volume, jobs};
    {
        BackupCoordinator coordinator(f.state, {}, true);
        coordinator.start();
        auto preview = coordinator.previewSetup(volume, {work});
        bool rejected = false;
        try {
            coordinator.confirmSetup(preview.id, {{preview.rows.front().id, "../invalid"}}, false, false);
        } catch (const std::runtime_error&) { rejected = true; }
        expect(rejected, "invalid setup must fail");
        preview = coordinator.previewSetup(volume, {work});
        coordinator.confirmSetup(preview.id, {}, false, false);
        auto snapshot = coordinator.presentation();
        expect(snapshot.folders.size() == 1 && snapshot.folders[0].mapping->folder == "Projects", "single mapping preserves its name");
        jobs.insert(snapshot.folders[0].job.id);
        preview = coordinator.previewSetup(volume, {personal});
        expect(preview.rows[0].folder() == "Work/Projects" && preview.rows[1].folder() == "Personal/Projects", "duplicate names get parent groups");
        coordinator.confirmSetup(preview.id, {}, false, false);
        snapshot = coordinator.presentation();
        expect(snapshot.folders.size() == 2, "adding a mapping retains the first job");
        for (const auto& folder : snapshot.folders) jobs.insert(folder.job.id);
        auto result = coordinator.sync();
        expect(result.state == SyncState::upToDate && result.sourceRead == 0 && result.targetRead == 0 &&
            result.latestWritten == 0 && result.historyWritten == 0, "quiet collections avoid body I/O");
        expect(coordinator.history().empty(), "moving a mapped folder does not archive unchanged data");
        fs::rename(work, work.parent_path() / "Design");
        result = coordinator.sync();
        expect(result.state == SyncState::upToDate, result.message);
        expect(read(Tree(volume), "BackupGenius/Work/Design/file.txt") == "first", "source folder rename follows the mapping");
        expect(result.latestWritten == 0, "source folder rename only moves paths");
        fs::rename(work.parent_path() / "Design", work.parent_path() / "design");
        result = coordinator.sync();
        expect(result.state == SyncState::upToDate, result.message);
        const auto children = Tree(volume).children("BackupGenius/Work");
        expect(std::find(children.begin(), children.end(), "design") != children.end(), "case-only source rename preserves its spelling");
        expect(result.latestWritten == 0, "case-only source rename does not copy content");
        write(Tree(personal), "file.txt", "edited");
        result = coordinator.sync(true);
        expect(result.state == SyncState::upToDate && read(Tree(volume), "BackupGenius/Personal/Projects/file.txt") == "edited",
            "other source continues to sync after regrouping");
    }
    BackupCoordinator reopened(f.state, {}, true);
    reopened.start();
    expect(reopened.presentation().folders.size() == 2, "collection config survives restart");
    expect(reopened.sync().state == SyncState::upToDate, "restarted collection can sync");
    fs::remove_all(work.parent_path() / "design");
    write(Tree(personal), "file.txt", "available");
    const auto partial = reopened.sync(true);
    expect(partial.state == SyncState::needsAttention, "missing source needs attention");
    expect(read(Tree(volume), "BackupGenius/Work/design/file.txt") == "first", "missing source preserves its copy");
    expect(read(Tree(volume), "BackupGenius/Personal/Projects/file.txt") == "available", "other mapping finishes after a source failure");
    for (auto source : {StorageMedium::unknown, StorageMedium::hdd, StorageMedium::ssd})
        for (auto target : {StorageMedium::unknown, StorageMedium::hdd, StorageMedium::ssd}) {
            const IOProfile profile(source, target);
            expect(profile.workers == (source == StorageMedium::ssd && target == StorageMedium::ssd ? 4 : 1), "I/O concurrency uses both devices");
            expect(profile.bufferBudget() <= IOProfile::bufferLimit, "I/O buffers stay within budget");
        }
}

void copySetFixture(const fs::path& source, const fs::path& target) {
    fs::create_directories(target);
    for (const auto& entry : fs::directory_iterator(source)) {
        if (utf8(entry.path().filename()).starts_with("._")) continue;
        const auto destination = target / entry.path().filename();
        if (entry.is_directory()) copySetFixture(entry.path(), destination);
        else fs::copy_file(entry.path(), destination, fs::copy_options::overwrite_existing);
    }
}
void setInterop(const fs::path& input, const fs::path& output, const fs::path& volume) {
    expect(!volume.empty() && inspect(volume).format == "exfat", "set interop requires a disposable exFAT volume");
    Fixture f;
    for (const auto& directory : {std::string(backupRoot), std::string(storageFolder)})
        copySetFixture(input / path(directory), volume / path(directory));
    const auto info = inspect(volume);
    auto set = *BackupSetStore::read(Tree(volume), info.format);
    const auto job = set.mappings.front().job;
    {
        BackupCoordinator coordinator(f.state, {}, true);
        coordinator.openExisting(volume / path(backupRoot));
        expect(coordinator.presentation().folders.size() == 1, "read Swift set");
        expect(coordinator.history().size() == 1, "read Swift set history");
        const auto source = f.source / "Source";
        fs::create_directory(source);
        const auto takeover = coordinator.previewTakeover(source);
        coordinator.confirmTakeover(takeover.id, {});
        auto expected = Bytes(2 * blockSize, 'A');
        expected[0] = 'M';
        expect(read(Tree(source), "payload.bin") == expected, "restore Swift set onto a new host");
        expected[blockSize] = 'W';
        write(Tree(source), "payload.bin", expected);
        const auto result = coordinator.sync(true);
        expect(result.state == SyncState::upToDate, result.message);
        expect(result.latestWritten == blockSize, "C++ set updates one logical block");
    }
    {
        BackupSetStore store(info, [](auto at) {
            if (at == SetInterruption::relocated) throw std::runtime_error("interrupted collection move");
        });
        set.revision += 1;
        set.mappings[0].folder = "Origin/Source";
        bool stopped = false;
        try { store.apply({set.revision - 1, set, {}, {{"Source", "Origin/Source", job}}}); }
        catch (...) { stopped = true; }
        expect(stopped, "C++ set move was interrupted after staging");
    }
    copySetFixture(volume / path(backupRoot), output / path(backupRoot));
    for (const auto& directory : {job, std::string("set")})
        copySetFixture(volume / path(join(storageFolder, directory)), output / path(join(storageFolder, directory)));
    std::error_code error;
    fs::remove_all(volume / path(backupRoot), error);
    for (const auto& directory : {job, std::string("set")})
        fs::remove_all(volume / path(join(storageFolder, directory)), error);
}

Json metrics(const SyncProgress& p) {
    return {{"checkingSeconds", p.checkingSeconds}, {"elapsedSeconds", p.elapsedSeconds}, {"examined", p.examined},
        {"sourceReadBytes", p.sourceRead}, {"targetReadBytes", p.targetRead}, {"latestWrittenBytes", p.latestWritten},
        {"historyWrittenBytes", p.historyWritten}, {"issues", p.issues}};
}
void benchmark(int count, const fs::path& volume, const fs::path& output) {
    expect(count >= 100 && count <= 1'000'000, "benchmark file count out of range");
    Fixture f(volume);
    Tree source(f.source);
    SyncEngine engine(f.state, {}, true);
    auto filename = [](int n, bool moved = false) {
        return "group-" + std::to_string(n / 100) + (moved ? "/moved-" : "/item-") + std::to_string(n);
    };
    for (int n = 0; n < count; ++n) {
        auto file = filename(n);
        if (n % 100 == 0) source.parents(file);
        // Data generation is outside the measured sync interval.
        Bytes bytes(1024, 'e');
        for (int i = 0; i < 8; ++i) bytes[i] = static_cast<char>(static_cast<uint64_t>(n) >> (i * 8));
        source.file(file, File::Mode::create).write(0, bytes);
    }
    Bytes payload(32 * 1024 * 1024, 'z');
    for (size_t i = 0; i < payload.size(); i += blockSize) {
        for (int j = 0; j < 8; ++j) payload[i + j] = static_cast<char>(static_cast<uint64_t>(i / blockSize) >> (j * 8));
    }
    write(source, "large.bin", payload);
    engine.configure(f.source, f.target, false);
    Json cases;
    cases["initial"] = metrics(engine.sync());
    engine.sync(); // Let notifications for our first commit settle.
    const auto idle = engine.sync();
    expect(!idle.sourceRead && !idle.targetRead && !idle.latestWritten && !idle.historyWritten, "benchmark no-op reads/writes");
    cases["unchanged"] = metrics(idle);
    Changes changes;
    for (int n = 0; n < count; n += 100) {
        auto file = filename(n);
        source.file(file, File::Mode::write).write(8, "m");
        changes.paths[file] = contentChange;
    }
    engine.recordChanges(changes);
    cases["editOnePercent"] = metrics(engine.sync());
    changes = {};
    for (int n = 0; n < count; n += 100) {
        source.rename(filename(n), filename(n, true));
        changes.paths[filename(n)] = nameChange;
        changes.paths[filename(n, true)] = nameChange;
    }
    engine.recordChanges(changes);
    cases["batchMove"] = metrics(engine.sync());
    source.file("large.bin", File::Mode::write).write(9 * blockSize + 9, "\x9c");
    engine.recordChanges({{{"large.bin", contentChange}}});
    auto patch = engine.sync();
    expect(patch.latestWritten == blockSize, "benchmark large-file patch");
    cases["largeFileOneBlock"] = metrics(patch);
    std::ofstream file(output, std::ios::binary);
    file << Json{{"files", count}, {"bytesPerFile", 1024}, {"filesystem", inspect(f.target).format},
        {"host",
#ifdef _WIN32
        "Windows"
#else
        "macOS POSIX test backend"
#endif
        }, {"cases", cases}}.dump(2) << '\n';
    expect(file.good(), "write benchmark report");
}
void interop(const fs::path& input, const fs::path& output, const fs::path& volume) {
    Fixture f(volume);
    fs::copy(input, f.target, fs::copy_options::recursive | fs::copy_options::copy_symlinks);
    auto source = Tree(f.source), disk = Tree(f.target);
    bool armed = false, interrupted = false;
    {
        SyncEngine engine(f.state, {}, true, [&](Interruption at) {
            if (armed && at == Interruption::firstBlock) { interrupted = true; throw std::runtime_error("injected cross-platform fault"); }
        });
        engine.openExisting(f.target);
        expect(read(disk, "payload.bin").front() == 'M', "Swift prepared edit rolled back");
        auto history = engine.history();
        expect(!history.empty(), "read Swift history");
        auto restored = Tree(engine.restore(f.restore, history[0].at("id").get<std::string>()));
        expect(read(restored, "payload.bin").front() == 'A', "read Swift packed data");
        auto preview = engine.previewTakeover(f.source);
        engine.confirmTakeover(preview.id, {});
        auto data = read(source, "payload.bin");
        data[blockSize] = 'W';
        write(source, "payload.bin", data);
        write(source, "windows.txt", "written by the C++ engine\n");
        engine.sync();
        expect(read(disk, "payload.bin") == data, "write compatible current copy");
        armed = true;
        data.front() = 'Z';
        write(source, "payload.bin", data);
        engine.recordChanges({{{"payload.bin", contentChange}}});
        try { engine.sync(); } catch (...) { if (!interrupted) throw; }
        expect(interrupted && disk.entry(pendingPath).has_value(), "export prepared C++ transaction");
    }
    expect(!fs::exists(output), "fixture output already exists");
    fs::create_directory(output);
    for (const auto& entry : fs::recursive_directory_iterator(f.target)) {
        // AppleDouble is generated by the local exFAT test backend. The fixture
        // contains portable byte streams with no user-created companion files.
        if (utf8(entry.path().filename()).starts_with("._")) continue;
        auto destination = output / entry.path().lexically_relative(f.target);
        if (entry.is_directory()) fs::create_directory(destination);
        else fs::copy_file(entry.path(), destination);
    }
}

int entry(std::vector<std::string> args) {
    try {
        if (args.size() == 5 && args[1] == "--benchmark") {
            benchmark(std::stoi(args[2]), path(args[3]), path(args[4]));
        } else if (args.size() == 5 && args[1] == "--set-interop") {
            setInterop(path(args[2]), path(args[3]), path(args[4]));
        } else if ((args.size() == 4 || args.size() == 5) && args[1] == "--interop") {
            interop(path(args[2]), path(args[3]), args.size() == 5 ? path(args[4]) : fs::path{});
        } else {
            auto volume = args.size() == 2 ? path(args[1]) : fs::path{};
            std::cout << "Incremental backup\n" << std::flush;
            incremental(volume);
            std::cout << "Interrupted transactions\n" << std::flush;
            for (auto at : {Interruption::prepared, Interruption::firstBlock, Interruption::applied, Interruption::committed})
                interrupted(volume, at);
            std::cout << "Takeover and safety\n" << std::flush;
            ownership(volume);
            safety(volume);
            macOnlyNames(volume);
            organizedRepository(volume);
            collectionRecovery(volume);
            collections(volume);
            pruning(volume);
#ifdef _WIN32
            liveEvents(volume);
#endif
            std::cout << "Passed: incremental, 4 interruption points, takeover, safety, pruning\n";
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
    std::vector<std::string> args;
    for (int i = 0; i < argc; ++i) args.push_back(utf8(fs::path(argv[i])));
    return entry(std::move(args));
}
#else
int main(int argc, char** argv) { return entry(std::vector<std::string>(argv, argv + argc)); }
#endif
