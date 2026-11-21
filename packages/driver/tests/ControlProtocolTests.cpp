#include "../src/ControlProtocol.hpp"
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <set>
#include <thread>

using namespace soundbridge;

static void check(bool condition, const char* label) {
    if (!condition) {
        std::cerr << "FAIL: " << label << '\n';
        std::exit(1);
    }
}

static void testMappingLeaseDuringDisconnect() {
    const size_t size = sizeof(RFSharedAudio);
    void* raw = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    check(raw != MAP_FAILED, "anonymous mapping fixture");
    auto owner = std::make_shared<SharedMemoryMapping>(static_cast<RFSharedAudio*>(raw), size);
    rf_shared_audio_init(owner->memory(), 48000, 2, RF_FORMAT_FLOAT32, 100);
    std::weak_ptr<SharedMemoryMapping> old = owner;
    PublishedSharedMemory published;
    published.store(owner);
    published.store(nullptr);
    check(!published.acquire(), "normal disconnect clears publication");
    published.store(owner);
    check(bool(published.acquire()), "normal reconnect permits publication");

    std::mutex mutex;
    std::condition_variable condition;
    bool acquired = false, disconnected = false;
    std::thread callback([&] {
        auto lease = published.acquire();
        check(bool(lease), "control callback acquired lease");
        {
            std::unique_lock<std::mutex> lock(mutex);
            acquired = true;
            condition.notify_one();
            condition.wait(lock, [&] { return disconnected; });
        }
        check(lease->memory()->sample_rate == 48000, "mapping survives disconnect");
        rf_store_volume_scalar(lease->memory(), 0.25f);
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return acquired; });
        published.retire();
        published.store(owner);
        owner.reset();
        check(!published.acquire() && !old.expired(), "retirement rejects new leases but preserves old lease");
        disconnected = true;
    }
    condition.notify_one();
    callback.join();
    check(old.expired(), "last callback releases mapping");
}

struct FakeSyncBackend {
    ControlSnapshot candidate;
    std::array<uint8_t, 16> liveSession{};
    LockStatus lock = LockStatus::held;
    std::map<std::string, HeartbeatStatus> heartbeats;
    std::set<std::string> devices;
    std::set<std::string> cooldown;
    std::vector<std::string> operations;
    bool loseLockOnHeartbeat = false;

    ControlSnapshot readControl() const { return candidate; }
    LockStatus hostLock(const ControlSnapshot& snapshot) const {
        if (lock != LockStatus::held) return lock;
        return snapshot.session == liveSession ? LockStatus::held : LockStatus::sessionMismatch;
    }
    HeartbeatStatus heartbeat(const std::string& uid, const ControlSnapshot&) {
        if (loseLockOnHeartbeat) lock = LockStatus::unheld;
        return heartbeats.at(uid);
    }
    void clearSession() {
        operations.push_back("clear");
        devices.clear();
        cooldown.clear();
    }
    std::vector<std::string> deviceUIDs() const { return {devices.begin(), devices.end()}; }
    bool hasDevice(const std::string& uid) const { return devices.count(uid) != 0; }
    bool inCooldown(const std::string& uid) const { return cooldown.count(uid) != 0; }
    void removeDevice(const std::string& uid) {
        operations.push_back("remove:" + uid);
        devices.erase(uid);
        cooldown.insert(uid);
    }
    void addDevice(const std::string&, const std::string& uid, const ControlSnapshot&) {
        operations.push_back("add:" + uid);
        devices.insert(uid);
    }
};

static void testSynchronizationWithRejectedControl() {
    const auto first = parseControl("#SB-CONTROL 1 01234567-89AB-CDEF-0123-456789ABCDEF 5 " +
                                    std::to_string(getuid()) + " 2\nA|a\nB|b");
    FakeSyncBackend backend;
    SessionTracker tracker;
    backend.candidate = first;
    backend.liveSession = first.session;
    backend.heartbeats = {{"a", HeartbeatStatus::fresh}, {"b", HeartbeatStatus::fresh}};
    check(synchronizeDevices(tracker, backend).decision == SessionDecision::adopted &&
          backend.devices == std::set<std::string>({"a", "b"}), "verified session creates devices");

    for (auto status : {ControlStatus::missing, ControlStatus::accessDenied, ControlStatus::ioError,
                        ControlStatus::temporaryFailure, ControlStatus::malformed,
                        ControlStatus::unsupportedVersion}) {
        backend.candidate.status = status;
        backend.operations.clear();
        synchronizeDevices(tracker, backend);
        check(backend.devices.size() == 2 && backend.operations.empty(),
              "invalid control preserves devices with fresh heartbeat");
    }
    backend.heartbeats["a"] = HeartbeatStatus::stale;
    backend.heartbeats["b"] = HeartbeatStatus::pending;
    synchronizeDevices(tracker, backend);
    check(backend.devices == std::set<std::string>({"b"}) &&
          backend.operations == std::vector<std::string>({"remove:a"}),
          "invalid control still removes a proven stale heartbeat");
    backend.operations.clear();
    backend.heartbeats["a"] = HeartbeatStatus::fresh;
    backend.cooldown.clear();
    synchronizeDevices(tracker, backend);
    check(backend.devices == std::set<std::string>({"b"}) && backend.operations.empty(),
          "invalid control cannot recreate devices");

    backend.candidate = first;
    backend.candidate.revision = first.revision - 1;
    backend.heartbeats["b"] = HeartbeatStatus::stale;
    check(synchronizeDevices(tracker, backend).decision == SessionDecision::rollback &&
          backend.devices.empty(), "rollback still checks accepted-session heartbeat");

    backend.candidate.status = ControlStatus::malformed;
    backend.lock = LockStatus::unheld;
    synchronizeDevices(tracker, backend);
    check(!tracker.active(), "released lock invalidates accepted session despite malformed control");

    auto next = first;
    check(parseSession("11234567-89AB-CDEF-0123-456789ABCDEF", next.session), "new session fixture");
    next.revision = 1;
    backend.lock = LockStatus::held;
    backend.liveSession = next.session;
    backend.candidate = next;
    backend.heartbeats["b"] = HeartbeatStatus::fresh;
    check(synchronizeDevices(tracker, backend).decision == SessionDecision::adopted &&
          backend.devices.size() == 2, "new session adopts fresh mappings");
    backend.candidate = first;
    backend.operations.clear();
    check(synchronizeDevices(tracker, backend).decision == SessionDecision::lockUnverified &&
          backend.operations.empty(), "late old session cannot replace live session");

    backend.candidate = next;
    backend.heartbeats["a"] = HeartbeatStatus::stale;
    backend.loseLockOnHeartbeat = true;
    backend.operations.clear();
    synchronizeDevices(tracker, backend);
    check(backend.operations.empty(), "lock lost during heartbeat prevents device mutation");
    synchronizeDevices(tracker, backend);
    check(!tracker.active() && backend.devices.empty(), "next pass removes orphaned devices");
}

int main() {
    testMappingLeaseDuringDisconnect();
    testSynchronizationWithRejectedControl();
    const std::string uuid = "01234567-89AB-CDEF-0123-456789ABCDEF";
    const std::string header = "#SB-CONTROL 1 " + uuid + " 5 " + std::to_string(getuid()) + " ";
    auto valid = parseControl(header + "2\nDisplay|uid-1\nHeadphones|uid-2");
    check(valid.status == ControlStatus::valid && valid.revision == 5 && valid.ownerUID == getuid(),
          "valid metadata");
    check(valid.devices.size() == 2 && valid.devices.at("uid-1") == "Display", "device rows");
    check(valid.session.front() == 0x01 && valid.session.back() == 0xEF, "UUID byte order");
    check(parseControl(header + "0").status == ControlStatus::valid, "valid empty set");
    check(parseControl("Display|uid-1").status == ControlStatus::malformed, "legacy rejected");
    check(parseControl("#SB-CONTROL 2 " + uuid + " 1 501 0").status == ControlStatus::unsupportedVersion,
          "unsupported version");
    check(parseControl(header + "2\nDisplay|uid-1").status == ControlStatus::malformed, "partial list");
    check(parseControl(header + "2\nA|uid\nB|uid").status == ControlStatus::malformed, "duplicate UID");
    check(parseControl(header + "1\nA|uid|extra").status == ControlStatus::malformed, "bad separator");
    check(parseControl(header + "0\ninvalid").status == ControlStatus::malformed, "invalid row not empty set");
    check(parseControl("#SB-CONTROL 1 bad 1 501 0").status == ControlStatus::malformed, "invalid session");
    check(parseControl("#SB-CONTROL 1 " + uuid + " 0 501 0").status == ControlStatus::malformed,
          "zero revision");
    check(parseControl("#SB-CONTROL 1 " + uuid + " 1 4294967296 0").status == ControlStatus::malformed,
          "owner overflow");
    check(classifyControlError(ENOENT) == ControlStatus::missing, "ENOENT");
    check(classifyControlError(EACCES) == ControlStatus::accessDenied, "EACCES");
    check(classifyControlError(EIO) == ControlStatus::ioError, "EIO");
    check(classifyControlError(EINTR) == ControlStatus::temporaryFailure, "temporary error");

    SessionTracker tracker;
    check(tracker.consider(parseControl("legacy|uid"), LockStatus::held, LockStatus::unheld) ==
          SessionDecision::invalid && !tracker.active(), "invalid control cannot establish session");
    check(tracker.consider(valid, LockStatus::unheld, LockStatus::unheld) ==
          SessionDecision::lockUnverified && !tracker.active(), "session requires held lock");
    check(tracker.consider(valid, LockStatus::held, LockStatus::unheld) == SessionDecision::adopted,
          "adopt verified session");
    auto older = valid;
    older.revision = 4;
    check(tracker.consider(older, LockStatus::held, LockStatus::held) == SessionDecision::rollback,
          "revision rollback rejected");
    auto changedAtSameRevision = valid;
    changedAtSameRevision.devices.clear();
    check(tracker.consider(changedAtSameRevision, LockStatus::held, LockStatus::held) ==
          SessionDecision::rollback, "revision cannot describe two device sets");
    auto empty = parseControl("#SB-CONTROL 1 " + uuid + " 6 " + std::to_string(getuid()) + " 0");
    check(tracker.consider(empty, LockStatus::held, LockStatus::held) == SessionDecision::refreshed &&
          tracker.snapshot().devices.empty(), "verified empty set accepted");
    auto next = parseControl("#SB-CONTROL 1 11234567-89AB-CDEF-0123-456789ABCDEF 1 " +
                             std::to_string(getuid()) + " 0");
    check(tracker.consider(next, LockStatus::held, LockStatus::held) == SessionDecision::conflict,
          "concurrent live session rejected");
    check(tracker.consider(next, LockStatus::held, LockStatus::unknown) == SessionDecision::conflict,
          "uncertain previous session rejected");
    check(tracker.consider(next, LockStatus::held, LockStatus::sessionMismatch) == SessionDecision::adopted,
          "replacement session adopted after previous identity changes");
    check(tracker.consider(valid, LockStatus::sessionMismatch, LockStatus::held) == SessionDecision::lockUnverified,
          "late old session rejected");
    tracker.reset();
    check(!tracker.active(), "session reset");

    char name[] = "/tmp/sb-control-test-XXXXXX";
    const int fd = mkstemp(name);
    check(fd >= 0, "temporary fixture");
    const std::string data = header + "1\nDisplay|uid-1";
    check(write(fd, data.data(), data.size()) == static_cast<ssize_t>(data.size()), "fixture write");
    close(fd);
    check(readControl(name).status == ControlStatus::valid, "real file read");
    check(unlink(name) == 0, "fixture cleanup");
    check(readControl(name).status == ControlStatus::missing, "real missing file");

    char lockName[] = "/tmp/sb-lock-test-XXXXXX";
    const int lockFD = mkstemp(lockName);
    check(lockFD >= 0, "lock fixture");
    std::array<uint8_t, 16> session{}, otherSession{};
    check(parseSession(uuid, session), "session fixture");
    check(parseSession("11234567-89AB-CDEF-0123-456789ABCDEF", otherSession), "other session fixture");
    RFSharedAudio memory{};
    rf_shared_audio_init(&memory, 48000, 2, RF_FORMAT_FLOAT32, 100);
    const size_t mappingSize = sizeof(memory) + size_t(memory.ring_capacity_frames) * memory.bytes_per_frame;
    check(!validateSharedMemory(&memory, mappingSize, session), "legacy mapping rejected");
    rf_set_host_session(&memory, session.data());
    check(validateSharedMemory(&memory, mappingSize, session), "session mapping accepted");
    check(!validateSharedMemory(&memory, mappingSize, otherSession), "old mapping session rejected");
    check(!validateSharedMemory(&memory, sizeof(memory) - 1, session), "short header rejected");
    check(!validateSharedMemory(&memory, mappingSize - 1, session), "short audio ring rejected");
    memory.ring_capacity_frames = UINT32_MAX;
    check(!validateSharedMemory(&memory, mappingSize, session), "overflowing ring rejected");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::unheld, "unheld lock");
    check(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "acquire fixture lock");
    const std::string record = "pid=" + std::to_string(getpid()) + " uid=" +
        std::to_string(getuid()) + " since=test session=" + uuid + "\n";
    check(write(lockFD, record.data(), record.size()) == static_cast<ssize_t>(record.size()), "write lock record");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::held, "held matching session");
    check(inspectHostLock(lockName, getuid(), otherSession) == LockStatus::sessionMismatch, "held other session");
    check(inspectHostLock(lockName, getuid() + 1, session) == LockStatus::unknown, "wrong owner");
    check(ftruncate(lockFD, static_cast<off_t>(record.size() - 1)) == 0, "truncate lock record");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::unknown, "incomplete record");
    check(flock(lockFD, LOCK_UN) == 0, "release fixture lock");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::unheld, "released lock");
    check(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "reacquire fixture lock");
    char replacement[] = "/tmp/sb-lock-test-replacement-XXXXXX";
    const int replacementFD = mkstemp(replacement);
    check(replacementFD >= 0, "replacement lock fixture");
    check(rename(replacement, lockName) == 0, "replace lock path");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::unheld, "replacement inode unheld");
    check(flock(lockFD, LOCK_UN) == 0, "release orphaned fixture lock");
    close(lockFD);
    close(replacementFD);
    check(unlink(lockName) == 0, "lock fixture cleanup");
    check(inspectHostLock(lockName, getuid(), session) == LockStatus::unheld, "missing lock");
    std::cout << "Control protocol tests passed\n";
}
