#pragma once

#include <atomic>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstdint>
#include <fcntl.h>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include "../include/RFSharedAudio.h"

namespace soundbridge {

enum class ControlStatus {
    valid,
    missing,
    accessDenied,
    ioError,
    temporaryFailure,
    malformed,
    unsupportedVersion
};

struct ControlSnapshot {
    ControlStatus status = ControlStatus::malformed;
    std::array<uint8_t, 16> session{};
    uint64_t revision = 0;
    uint32_t ownerUID = 0;
    std::map<std::string, std::string> devices;
};

inline ControlStatus classifyControlError(int code) {
    switch (code) {
        case ENOENT: return ControlStatus::missing;
        case EACCES: case EPERM: return ControlStatus::accessDenied;
        case EIO: return ControlStatus::ioError;
        default: return ControlStatus::temporaryFailure;
    }
}

inline bool parseNumber(const std::string& text, uint64_t& value) {
    if (text.empty()) return false;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

inline int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

inline bool parseSession(const std::string& text, std::array<uint8_t, 16>& bytes) {
    if (text.size() != 36) return false;
    size_t output = 0;
    bool nonzero = false;
    for (size_t i = 0; i < text.size();) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (text[i++] != '-') return false;
            continue;
        }
        if (i + 1 >= text.size() || output >= bytes.size()) return false;
        const int high = hexDigit(text[i]);
        const int low = hexDigit(text[i + 1]);
        if (high < 0 || low < 0) return false;
        bytes[output++] = static_cast<uint8_t>((high << 4) | low);
        nonzero = nonzero || high != 0 || low != 0;
        i += 2;
    }
    return output == bytes.size() && nonzero;
}

inline ControlSnapshot parseControl(const std::string& contents) {
    ControlSnapshot result;
    if (contents.find('\0') != std::string::npos || contents.find('\r') != std::string::npos) return result;
    std::istringstream input(contents);
    std::string header;
    if (!std::getline(input, header)) return result;

    std::istringstream fields(header);
    std::string magic, versionText, sessionText, revisionText, ownerText, countText, extra;
    if (!(fields >> magic >> versionText >> sessionText >> revisionText >> ownerText >> countText) ||
        fields >> extra || magic != "#SB-CONTROL") return result;

    uint64_t version = 0, revision = 0, owner = 0, count = 0;
    if (!parseNumber(versionText, version)) return result;
    if (version != 1) {
        result.status = ControlStatus::unsupportedVersion;
        return result;
    }
    if (!parseSession(sessionText, result.session) ||
        !parseNumber(revisionText, revision) || revision == 0 ||
        !parseNumber(ownerText, owner) || owner > std::numeric_limits<uint32_t>::max() ||
        !parseNumber(countText, count) || count > 65535) return result;

    std::string line;
    while (std::getline(input, line)) {
        const size_t separator = line.find('|');
        if (separator == std::string::npos || separator == 0 || separator + 1 == line.size() ||
            line.find('|', separator + 1) != std::string::npos) return ControlSnapshot{};
        if (!result.devices.emplace(line.substr(separator + 1), line.substr(0, separator)).second)
            return ControlSnapshot{};
    }
    if (result.devices.size() != count) return ControlSnapshot{};
    result.status = ControlStatus::valid;
    result.revision = revision;
    result.ownerUID = static_cast<uint32_t>(owner);
    return result;
}

inline ControlSnapshot readControl(const char* path) {
    constexpr size_t maximumBytes = 1024 * 1024;
    ControlSnapshot result;
    const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        result.status = classifyControlError(errno);
        return result;
    }
    struct stat info{};
    if (fstat(fd, &info) != 0) {
        result.status = classifyControlError(errno);
        close(fd);
        return result;
    }
    if (!S_ISREG(info.st_mode) || info.st_size < 0 || static_cast<uint64_t>(info.st_size) > maximumBytes) {
        close(fd);
        return result;
    }
    std::string content;
    char buffer[4096];
    for (;;) {
        const ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
            result.status = classifyControlError(errno);
            close(fd);
            return result;
        }
        if (n == 0) break;
        content.append(buffer, static_cast<size_t>(n));
        if (content.size() > maximumBytes) {
            close(fd);
            return result;
        }
    }
    close(fd);
    result = parseControl(content);
    if (result.status == ControlStatus::valid && info.st_uid != result.ownerUID) {
        return ControlSnapshot{};
    }
    return result;
}

inline bool validateSharedMemory(const RFSharedAudio* mem, size_t fileSize,
                                 const std::array<uint8_t, 16>& session) {
    if (fileSize < sizeof(RFSharedAudio) || fileSize > 64u * 1024u * 1024u ||
        rf_validate_header(mem) != RF_VALIDATE_OK || !rf_host_session_matches(mem, session.data()) ||
        mem->format > RF_FORMAT_INT32 || mem->ring_capacity_frames == 0) return false;
    const uint32_t bytesPerSample = rf_bytes_per_sample(static_cast<RFAudioFormat>(mem->format));
    if (mem->bytes_per_sample != bytesPerSample ||
        mem->bytes_per_frame != mem->channels * bytesPerSample) return false;
    return mem->ring_capacity_frames <=
        (fileSize - sizeof(RFSharedAudio)) / mem->bytes_per_frame;
}

// 控件回调可能与 StopIO 并发；持有租约的回调结束前不能解除映射。
class SharedMemoryMapping {
public:
    SharedMemoryMapping(RFSharedAudio* memory, size_t size) : memory_(memory), size_(size) {}
    SharedMemoryMapping(const SharedMemoryMapping&) = delete;
    SharedMemoryMapping& operator=(const SharedMemoryMapping&) = delete;
    ~SharedMemoryMapping() { if (memory_) munmap(memory_, size_); }

    RFSharedAudio* memory() const { return memory_; }
    size_t size() const { return size_; }

private:
    RFSharedAudio* memory_;
    size_t size_;
};

class PublishedSharedMemory {
public:
    void store(std::shared_ptr<SharedMemoryMapping> mapping) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!retired_) mapping_.swap(mapping);
    }
    std::shared_ptr<SharedMemoryMapping> acquire() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return mapping_;
    }
    void retire() {
        std::shared_ptr<SharedMemoryMapping> previous;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            retired_ = true;
            mapping_.swap(previous);
        }
    }

private:
    mutable std::mutex mutex_;
    bool retired_ = false;
    std::shared_ptr<SharedMemoryMapping> mapping_;
};

enum class LockStatus { held, unheld, sessionMismatch, unknown };

// 只有内核锁冲突、稳定 inode 和完整记录同时成立时才接受会话。
inline LockStatus inspectHostLock(const char* path, uint32_t ownerUID,
                                  const std::array<uint8_t, 16>& expected) {
    const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? LockStatus::unheld : LockStatus::unknown;
    struct stat opened{}, current{};
    if (fstat(fd, &opened) != 0 || lstat(path, &current) != 0 ||
        !S_ISREG(opened.st_mode) || opened.st_uid != ownerUID ||
        opened.st_dev != current.st_dev || opened.st_ino != current.st_ino) {
        close(fd);
        return LockStatus::unknown;
    }
    auto held = [fd]() -> LockStatus {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            flock(fd, LOCK_UN);
            return LockStatus::unheld;
        }
        return (errno == EWOULDBLOCK || errno == EAGAIN) ? LockStatus::held : LockStatus::unknown;
    };
    const LockStatus first = held();
    if (first != LockStatus::held) {
        close(fd);
        return first;
    }
    char buffer[512];
    const ssize_t size = pread(fd, buffer, sizeof(buffer), 0);
    if (size <= 0 || size == static_cast<ssize_t>(sizeof(buffer)) || buffer[size - 1] != '\n') {
        close(fd);
        return LockStatus::unknown;
    }
    std::istringstream record(std::string(buffer, static_cast<size_t>(size)));
    std::string part;
    bool haveUID = false, haveSession = false;
    std::array<uint8_t, 16> actual{};
    while (record >> part) {
        if (part.rfind("uid=", 0) == 0) {
            uint64_t value = 0;
            if (haveUID || !parseNumber(part.substr(4), value) || value != ownerUID) {
                close(fd);
                return LockStatus::unknown;
            }
            haveUID = true;
        } else if (part.rfind("session=", 0) == 0) {
            if (haveSession || !parseSession(part.substr(8), actual)) {
                close(fd);
                return LockStatus::unknown;
            }
            haveSession = true;
        }
    }
    char again[512];
    const ssize_t secondSize = pread(fd, again, sizeof(again), 0);
    const bool unchanged = secondSize == size &&
        std::string(buffer, static_cast<size_t>(size)) == std::string(again, static_cast<size_t>(size));
    const LockStatus second = held();
    const bool samePath = lstat(path, &current) == 0 && opened.st_dev == current.st_dev &&
        opened.st_ino == current.st_ino;
    close(fd);
    if (!haveUID || !haveSession || !unchanged || !samePath || second != LockStatus::held)
        return LockStatus::unknown;
    return actual == expected ? LockStatus::held : LockStatus::sessionMismatch;
}

enum class SessionDecision { adopted, refreshed, invalid, lockUnverified, rollback, conflict };

// 调用方必须串行化访问；锁证据只表示检查时刻，不能代替内核级身份事务。
class SessionTracker {
public:
    SessionDecision consider(const ControlSnapshot& candidate, LockStatus candidateLock,
                             LockStatus previousLock) {
        if (candidate.status != ControlStatus::valid) return SessionDecision::invalid;
        if (candidateLock != LockStatus::held) return SessionDecision::lockUnverified;
        if (active_) {
            const bool same = snapshot_.ownerUID == candidate.ownerUID && snapshot_.session == candidate.session;
            if (same) {
                if (candidate.revision < snapshot_.revision ||
                    (candidate.revision == snapshot_.revision && candidate.devices != snapshot_.devices))
                    return SessionDecision::rollback;
                snapshot_ = candidate;
                return SessionDecision::refreshed;
            }
            if (previousLock == LockStatus::held || previousLock == LockStatus::unknown)
                return SessionDecision::conflict;
        }
        snapshot_ = candidate;
        active_ = true;
        return SessionDecision::adopted;
    }

    bool active() const { return active_; }
    const ControlSnapshot& snapshot() const { return snapshot_; }
    void reset() { active_ = false; snapshot_ = ControlSnapshot{}; }

private:
    bool active_ = false;
    ControlSnapshot snapshot_;
};

enum class HeartbeatStatus { fresh, pending, stale };

struct SyncResult {
    ControlStatus controlStatus = ControlStatus::malformed;
    SessionDecision decision = SessionDecision::invalid;
};

// Backend 负责串行化调用并提供锁、文件、心跳和设备操作。读取失败时只检查
// 已验证会话中现有设备的过期心跳；不能由失败数据创建设备或推断空集合。
template <typename Backend>
SyncResult synchronizeDevices(SessionTracker& session, Backend& backend) {
    LockStatus previousLock = LockStatus::unheld;
    if (session.active()) {
        previousLock = backend.hostLock(session.snapshot());
        if (previousLock == LockStatus::unheld || previousLock == LockStatus::sessionMismatch) {
            backend.clearSession();
            session.reset();
        }
    }

    const auto candidate = backend.readControl();
    SyncResult result;
    result.controlStatus = candidate.status;
    bool accepted = false;
    if (candidate.status == ControlStatus::valid) {
        result.decision = session.consider(candidate, backend.hostLock(candidate), previousLock);
        accepted = result.decision == SessionDecision::adopted ||
                   result.decision == SessionDecision::refreshed;
        if (result.decision == SessionDecision::adopted) backend.clearSession();
    }

    if (!session.active()) return result;
    // 使用副本：后续回调不应改变本轮的已接受设备集合。
    const auto snapshot = session.snapshot();
    if (backend.hostLock(snapshot) != LockStatus::held) return result;

    std::map<std::string, HeartbeatStatus> heartbeat;
    for (const auto& [uid, name] : snapshot.devices) {
        (void)name;
        heartbeat[uid] = backend.heartbeat(uid, snapshot);
    }
    // 文件和心跳读取期间可能发生锁转移；该检查仍不是原子事务。
    if (backend.hostLock(snapshot) != LockStatus::held) return result;

    for (const auto& uid : backend.deviceUIDs()) {
        const auto it = heartbeat.find(uid);
        if ((accepted && it == heartbeat.end()) ||
            (it != heartbeat.end() && it->second == HeartbeatStatus::stale)) {
            backend.removeDevice(uid);
        }
    }
    if (!accepted) return result;
    for (const auto& [uid, name] : snapshot.devices) {
        if (heartbeat.at(uid) == HeartbeatStatus::fresh && !backend.hasDevice(uid) &&
            !backend.inCooldown(uid)) {
            backend.addDevice(name, uid, snapshot);
        }
    }
    return result;
}

} // namespace soundbridge
