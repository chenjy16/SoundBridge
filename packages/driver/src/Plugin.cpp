// SoundBridge HAL driver implementation.

#include <aspl/Driver.hpp>
#include <aspl/VolumeControl.hpp>
#include <aspl/MuteControl.hpp>
#include "VolumeCurve.hpp"
#include <CoreAudio/AudioServerPlugIn.h>

#include "../include/RFSharedAudio.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <atomic>
#include <thread>
#include <chrono>
#include <os/log.h>
#include <map>
#include <string>
#include <fstream>
#include <sstream>
#include <vector>
#include <set>
#include <sys/stat.h>
#include <errno.h>
#include <mutex>
#include <algorithm>
#include <cstdarg>
#include <mach/mach_time.h>
#include <notify.h>
#include "ControlProtocol.hpp"
#include "MappingRetirement.hpp"
#include "ProducerToken.hpp"

// Logging
static os_log_t rf_log = os_log_create("com.soundbridge.driver", "default");

#define RF_LOG_ERROR(fmt, ...) os_log_error(rf_log, "[SoundBridge ERROR] " fmt, ##__VA_ARGS__)
#define RF_LOG_INFO(fmt, ...) os_log_info(rf_log, "[SoundBridge INFO] " fmt, ##__VA_ARGS__)
#define RF_LOG_DEBUG(fmt, ...) os_log_debug(rf_log, "[SoundBridge DEBUG] " fmt, ##__VA_ARGS__)

// Fallback file logger for debugging when unified logs are unavailable.
static void RF_DebugLog(const char* fmt, ...) {
    static std::mutex log_mutex;
    std::lock_guard<std::mutex> lock(log_mutex);
    FILE* f = fopen("/tmp/soundbridge-driver-debug.log", "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    fprintf(f, "\n");
    va_end(args);
    fclose(f);
}

namespace {

// Configuration
constexpr UInt32 DEFAULT_SAMPLE_RATE = 48000;
constexpr UInt32 DEFAULT_CHANNELS = 2;
constexpr UInt32 DEFAULT_RING_DURATION_MS = RF_RING_DURATION_MS_DEFAULT;

// ===== Lock-free requirements of the realtime write callback (Batch 3 Closure Fix)
//
// The HAL write callback runs on a render thread and must never acquire a lock.
// C++ only guarantees an atomic operation is lock-free in practice -- a
// conforming implementation may also impose a lock, and until C++17 there was no
// way to ask at compile time. is_always_lock_free is a constant expression, so a
// target ABI that could not honour these fails the build instead of quietly
// taking a mutex inside the callback.
//
// The set below is exactly what OnWriteMixedOutput touches:
//
//   stats_.total_writes / failed_writes   std::atomic<uint64_t>
//   retired_ (admission fast path)        std::atomic<bool>
//   shared_memory_ (published mapping)    std::atomic<RFSharedAudio*>
//   callback_gate_ admission word         std::atomic<uint32_t>
//                                         (asserted in MappingRetirement.hpp)
//
// Deliberately NOT asserted: atomics only control threads touch
// (claimed_epoch_, io_client_count_, mapping_revision_, state_,
// suppress_shared_memory_write_). Lock freedom would still be nice there, but it
// is not a realtime requirement, and asserting requirements the code does not
// have makes the list drift away from the code.
//
// Lock-free is not wait-free: a fetch_add may still lose the cache line to
// another core and retry in hardware. Nothing here promises a cycle bound.
static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "realtime stats counters must be lock-free on the target ABI");
static_assert(std::atomic<bool>::is_always_lock_free,
              "retired_ is read on the realtime path and must be lock-free");
static_assert(std::atomic<RFSharedAudio*>::is_always_lock_free,
              "the published mapping pointer is read on the realtime path and must be lock-free");

// ===== Volume taper =====
// The proxy device advertises a 48 dB / 48-step taper so that libASPL's Pow2
// transfer function yields exactly:
//
//     raw = round(sqrt(scalar) * 48)      dB = 48 * sqrt(scalar) - 48
//
// which is the same curve the Host applies to its render gain (see
// VolumeTaper.swift and the RF_VOLUME_* block in RFSharedAudio.h).
//
// libASPL applies the Pow2 transfer function ONLY when the dB range exceeds
// 30 dB (vendor/libASPL/src/VolumeCurve.cpp). The previous 96 dB range also
// took the non-linear branch, but the Host mapped the scalar *linearly* onto
// 48 dB, so the two sides disagreed by up to ~29 dB at low volumes.
// Shrinking this range below 30 dB would silently make the curve linear again;
// the static_assert below and the one in RFSharedAudio.h both exist to turn
// that into a build failure instead of a silent 29 dB error.
constexpr SInt32 VOLUME_RAW_MIN = RF_VOLUME_RAW_MIN;   // 0
constexpr SInt32 VOLUME_RAW_MAX = RF_VOLUME_RAW_MAX;   // 48
constexpr Float32 VOLUME_DB_MIN = RF_VOLUME_DB_MIN;    // -48 dB
constexpr Float32 VOLUME_DB_MAX = RF_VOLUME_DB_MAX;    // 0 dB
static_assert(VOLUME_DB_MAX - VOLUME_DB_MIN > 30.0f,
    "Volume dB range must stay above 30 dB, otherwise libASPL silently "
    "degrades the taper to linear and disagrees with the Host gain stage");
static_assert(VOLUME_RAW_MAX > VOLUME_RAW_MIN,
    "Volume raw range must be non-empty");
// CoreAudio AudioServerPlugIn.h documents a minimum allowed zero timestamp period
// of 10923 frames. Use a conservative ring-sized period common to virtual drivers.
constexpr UInt32 HAL_ZERO_TIMESTAMP_PERIOD_FRAMES = 16384;
constexpr UInt32 HAL_SAFETY_OFFSET_FRAMES = 128;
constexpr UInt32 HAL_PRESENTATION_LATENCY_FRAMES = 512;
static_assert(HAL_ZERO_TIMESTAMP_PERIOD_FRAMES >= 10923,
    "ZeroTimeStampPeriod must satisfy CoreAudio minimum (10923 frames)");
constexpr int ADAPTIVE_FILL_TARGET_DIVISOR = 2;     // Keep ring near 50% full
constexpr int ADAPTIVE_FILL_DEADBAND_PERCENT = 20;  // Ignore fill variance within ±20%
constexpr double ADAPTIVE_MAX_ADJUST_PPM = 1500.0;  // +/-0.15% drift correction

// Health and heartbeat timing constants.
constexpr int HEALTH_CHECK_INTERVAL_SEC = 3;
constexpr int HEARTBEAT_INTERVAL_SEC = 1;
constexpr int STATS_LOG_INTERVAL_SEC = 30;
constexpr int HEARTBEAT_TIMEOUT_SEC = 15;

// ===== OnStartIO shared-memory acquisition budget =====
//
// The Host creates the shared-memory file well before it starts IO
// (main.swift: createMemory() runs at step 3, audioEngine.start() at step 8),
// so a long backoff buys nothing — and it costs: OnStartIO sits on the HAL
// start path. The old loop ran 15 attempts with exponential backoff and
// accumulated 30+60+120+240+480+960+1920*8 = 17 250 ms before failing.
//
// First try + 2 retries, sleeping 50 ms then 100 ms => worst case 150 ms.
constexpr int MAX_START_IO_ATTEMPTS = 3;    // includes the first attempt
constexpr int START_IO_BASE_DELAY_MS = 50;  // attempt 1 -> 50 ms, attempt 2 -> 100 ms
static_assert(MAX_START_IO_ATTEMPTS >= 1, "At least one attempt is required");
static_assert(START_IO_BASE_DELAY_MS > 0, "Retry delay must be positive");

// Worst-case accumulated sleep: BASE * (2^0 + ... + 2^(N-2))
constexpr int START_IO_MAX_BLOCKING_MS =
    START_IO_BASE_DELAY_MS * ((1 << (MAX_START_IO_ATTEMPTS - 1)) - 1);
static_assert(START_IO_MAX_BLOCKING_MS <= 300,
    "OnStartIO must not block the HAL start path for more than 300 ms");

// Device cycling prevention - minimum time between remove and re-add
constexpr int DEVICE_COOLDOWN_SEC = 10;

// Device states
enum class DeviceState {
    Uninitialized,
    Connecting,
    Connected,
    Negotiating,    // Format negotiation in progress
    Error,
    Disconnected
};

const char* StateToString(DeviceState state) {
    switch (state) {
        case DeviceState::Uninitialized: return "Uninitialized";
        case DeviceState::Connecting: return "Connecting";
        case DeviceState::Connected: return "Connected";
        case DeviceState::Negotiating: return "Negotiating";
        case DeviceState::Error: return "Error";
        case DeviceState::Disconnected: return "Disconnected";
        default: return "Unknown";
    }
}

// Sample rate conversion (simple linear interpolation)
class SimpleResampler {
public:
    SimpleResampler(double from_rate, double to_rate, uint32_t channels)
        : from_rate_(from_rate), to_rate_(to_rate), channels_(channels), ratio_(1.0), position_(0.0)
    {
        SetRates(from_rate, to_rate);
        RF_LOG_INFO("Resampler: %.2f -> %.2f Hz (ratio: %.8f)", from_rate_, to_rate_, ratio_);
    }

    void SetRates(double from_rate, double to_rate)
    {
        if (from_rate <= 0.0) from_rate = 48000.0;
        if (to_rate <= 0.0) to_rate = from_rate;
        from_rate_ = from_rate;
        to_rate_ = to_rate;
        ratio_ = from_rate_ / to_rate_;
    }

    void SetChannels(uint32_t channels)
    {
        channels_ = std::max<uint32_t>(1, channels);
    }

    // Resample input to output
    // Returns number of output frames produced
    uint32_t Process(const float* input, uint32_t input_frames,
                     float* output, uint32_t output_capacity)
    {
        uint32_t output_frames = 0;

        while (output_frames < output_capacity && position_ < input_frames) {
            uint32_t idx0 = (uint32_t)position_;
            uint32_t idx1 = std::min(idx0 + 1, input_frames - 1);
            float frac = position_ - idx0;

            for (uint32_t ch = 0; ch < channels_; ch++) {
                float s0 = input[idx0 * channels_ + ch];
                float s1 = input[idx1 * channels_ + ch];
                output[output_frames * channels_ + ch] = s0 + frac * (s1 - s0);
            }

            output_frames++;
            position_ += ratio_;
        }

        position_ -= input_frames;
        if (position_ < 0.0) {
            position_ = 0.0;
        }
        return output_frames;
    }

    void Reset() { position_ = 0.0; }

private:
    double from_rate_;
    double to_rate_;
    uint32_t channels_;
    double ratio_;
    double position_;
};

// Runtime statistics.
struct AudioStats {
    std::atomic<uint64_t> total_writes{0};
    std::atomic<uint64_t> failed_writes{0};
    std::atomic<uint64_t> health_failures{0};
    std::atomic<uint64_t> reconnections{0};
    std::atomic<uint64_t> format_changes{0};
    std::atomic<uint64_t> sample_rate_conversions{0};
    std::atomic<uint64_t> client_starts{0};
    std::atomic<uint64_t> client_stops{0};

    void LogPeriodic() {
        static auto last_log = std::chrono::steady_clock::now();
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - last_log).count();

        if (elapsed >= STATS_LOG_INTERVAL_SEC) {
            RF_LOG_INFO("╔══════════════ STATS (%llds) ══════════════╗", elapsed);
            RF_LOG_INFO("║ Writes: %llu (failed: %llu)              ", total_writes.load(), failed_writes.load());
            RF_LOG_INFO("║ Clients: starts=%llu stops=%llu          ", client_starts.load(), client_stops.load());
            RF_LOG_INFO("║ Health: failures=%llu reconnects=%llu    ", health_failures.load(), reconnections.load());
            RF_LOG_INFO("║ Format: changes=%llu SRC=%llu            ", format_changes.load(), sample_rate_conversions.load());
            RF_LOG_INFO("╚══════════════════════════════════════════╝");
            last_log = now;
        }
    }
};

// Custom VolumeControl that syncs to shared memory when volume changes.
// This intercepts macOS volume changes (via kAudioLevelControlPropertyScalarValue)
// and writes them to shared memory for the Host process to read.
class SoundBridgeVolumeControl : public aspl::VolumeControl {
public:
    SoundBridgeVolumeControl(std::shared_ptr<const aspl::Context> context,
                             const aspl::VolumeControlParameters& params = {})
        : aspl::VolumeControl(context, params)
    {
    }

    void SetSharedMemory(std::shared_ptr<soundbridge::SharedMemoryMapping> mapping) {
        shared_memory_.store(std::move(mapping));
    }
    void Retire() { shared_memory_.retire(); }

    // Push a value INTO the control without echoing it back to shared memory.
    //
    // The scalar<->raw conversion is lossy (48 raw steps), so a plain
    // SetScalarValue() would write the quantised value straight back over the
    // exact value the Host committed. Restoring state must be a one-way push.
    OSStatus RestoreFromSharedMemory(Float32 scalar) {
        suppress_shared_memory_write_.store(true, std::memory_order_release);
        OSStatus status = SetScalarValue(scalar);
        suppress_shared_memory_write_.store(false, std::memory_order_release);
        return status;
    }

protected:
    OSStatus SetRawValueImpl(SInt32 value) override {
        OSStatus status = aspl::VolumeControl::SetRawValueImpl(value);
        const auto mapping = shared_memory_.acquire();
        if (status == kAudioHardwareNoError && mapping) {
            if (suppress_shared_memory_write_.load(std::memory_order_acquire)) {
                RF_DebugLog("SoundBridgeVolumeControl: internal restore to raw=%d (not echoed to shared memory)", value);
                return status;
            }
            Float32 scalar = GetScalarValue();
            rf_store_volume_scalar(mapping->memory(), scalar);
            RF_DebugLog("SoundBridgeVolumeControl: volume changed to %.3f (raw=%d)", scalar, value);
        }
        return status;
    }

private:
    soundbridge::PublishedSharedMemory shared_memory_;
    std::atomic<bool> suppress_shared_memory_write_{false};
};

// Custom MuteControl that syncs to shared memory when mute changes.
class SoundBridgeMuteControl : public aspl::MuteControl {
public:
    SoundBridgeMuteControl(std::shared_ptr<const aspl::Context> context,
                           const aspl::MuteControlParameters& params = {})
        : aspl::MuteControl(context, params)
    {
    }

    void SetSharedMemory(std::shared_ptr<soundbridge::SharedMemoryMapping> mapping) {
        shared_memory_.store(std::move(mapping));
    }
    void Retire() { shared_memory_.retire(); }

    // See SoundBridgeVolumeControl::RestoreFromSharedMemory().
    OSStatus RestoreFromSharedMemory(bool muted) {
        suppress_shared_memory_write_.store(true, std::memory_order_release);
        OSStatus status = SetIsMuted(muted);
        suppress_shared_memory_write_.store(false, std::memory_order_release);
        return status;
    }

protected:
    OSStatus SetIsMutedImpl(bool isMuted) override {
        OSStatus status = aspl::MuteControl::SetIsMutedImpl(isMuted);
        const auto mapping = shared_memory_.acquire();
        if (status == kAudioHardwareNoError && mapping) {
            if (suppress_shared_memory_write_.load(std::memory_order_acquire)) {
                RF_DebugLog("SoundBridgeMuteControl: internal restore to %d (not echoed to shared memory)", isMuted ? 1 : 0);
                return status;
            }
            rf_store_mute_state(mapping->memory(), isMuted ? 1 : 0);
            RF_DebugLog("SoundBridgeMuteControl: mute changed to %d", isMuted ? 1 : 0);
        }
        return status;
    }

private:
    soundbridge::PublishedSharedMemory shared_memory_;
    std::atomic<bool> suppress_shared_memory_write_{false};
};

// Custom Device subclass with correct GetZeroTimeStamp implementation.
// libASPL's default GetZeroTimeStampImpl only increments periodCounter_ by 1 per
// call. If the HAL calls GetZeroTimeStamp late, the counter can fall behind and
// never catch up, causing monotonic clock drift that Safari's Web Audio
// drift-compensation interprets as stutter.
// This override computes elapsed periods via integer division from an anchor time.
class SoundBridgeDevice : public aspl::Device {
public:
    SoundBridgeDevice(std::shared_ptr<aspl::Context> context,
                    const aspl::DeviceParameters& params)
        : aspl::Device(context, params)
        , anchorTime_(0)
        , periodCounter_(0)
        , hostTicksPerFrame_(0)
        , lastSampleRate_(0)
        , hostClockFreq_(0)
        , clockSeed_(1)
    {
        // Cache mach timebase at construction (non-RT-safe syscall).
        // The ratio is a hardware constant and does not change at runtime.
        struct mach_timebase_info tb = {};
        mach_timebase_info(&tb);
        // Guard against failure (numer==0). Fallback 1e9 = 1ns/tick, correct for Apple Silicon.
        hostClockFreq_ = (tb.numer > 0)
            ? Float64(tb.denom) / Float64(tb.numer) * 1.0e9
            : 1.0e9;
    }

    // Volume/Mute properties are handled entirely by SoundBridgeVolumeControl
    // and SoundBridgeMuteControl (added via AddVolumeControlAsync/AddMuteControlAsync).
    // libASPL's base Device class automatically routes volume/mute queries to
    // those control objects — no Device-level overrides needed.

protected:
    // StartIOImpl intentionally not overridden. The anchor is set once lazily in
    // GetZeroTimeStampImpl and never reset, keeping the clock timeline continuous
    // across IO start/stop cycles and preventing the cold-start underrun that
    // triggers Safari's Web Audio stutter.

    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) override
    {
        const UInt64 now = mach_absolute_time();

        // Ensure a deterministic anchor even if StartIOImpl has not run yet.
        if (anchorTime_ == 0) {
            anchorTime_ = now;
            periodCounter_ = 0;
        }

        // Recompute host ticks per frame on sample rate change
        Float64 sampleRate = GetNominalSampleRate();
        if (sampleRate <= 0) {
            sampleRate = (lastSampleRate_ > 0) ? lastSampleRate_ : 48000.0;
        }
        if (hostTicksPerFrame_ <= 0) {
            // First initialization — set rate, no anchor reset needed.
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
        } else if (sampleRate != lastSampleRate_) {
            // Genuine sample-rate change: re-anchor to now so outSampleTime stays
            // monotonic, and bump seed so the HAL knows to re-sync its IO timeline.
            anchorTime_ = now;
            periodCounter_ = 0;
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
            ++clockSeed_;
        }

        const Float64 period = GetZeroTimeStampPeriod();
        if (period <= 0 || hostTicksPerFrame_ <= 0) {
            *outSampleTime = 0;
            *outHostTime = anchorTime_;
            *outSeed = clockSeed_;
            return kAudioHardwareNoError;
        }
        const Float64 ticksPerPeriod = hostTicksPerFrame_ * period;

        // Compute elapsed periods from anchor using division (not single increment)
        if (ticksPerPeriod > 0 && now >= anchorTime_) {
            UInt64 elapsed = now - anchorTime_;
            UInt64 periods = (UInt64)(Float64(elapsed) / ticksPerPeriod);
            periodCounter_ = periods;
        }

        *outSampleTime = periodCounter_ * period;
        *outHostTime = anchorTime_ + UInt64(Float64(periodCounter_) * ticksPerPeriod);
        *outSeed = clockSeed_;
        return kAudioHardwareNoError;
    }

private:
    // Thread-safety: libASPL's top-level StartIO()/GetZeroTimeStamp() take
    // Device::ioMutex_ before invoking these Impl overrides, so these fields are
    // serialized by the base class and do not need extra atomics here.
    UInt64 anchorTime_;
    UInt64 periodCounter_;
    Float64 hostTicksPerFrame_;
    Float64 lastSampleRate_;
    Float64 hostClockFreq_;  // (tb.denom/tb.numer)*1e9, cached at construction
    UInt64 clockSeed_;       // increments on sample-rate change to signal HAL re-sync

    // Volume/Mute state is owned by SoundBridgeVolumeControl/MuteControl objects.
    // No Device-level volume/mute members needed.
};

static soundbridge::LockStatus HostLockStatus(uint32_t ownerUID, const std::array<uint8_t, 16>& session) {
    const std::string path = std::string(RF_INSTANCE_LOCK_PATH_PREFIX) + std::to_string(ownerUID) +
        RF_INSTANCE_LOCK_PATH_SUFFIX;
    return soundbridge::inspectHostLock(path.c_str(), ownerUID, session);
}

// ===== Producer owner token (Batch 2) =====
//
// The token itself is generated by soundbridge::GenerateProducerOwnerToken()
// (src/ProducerToken.hpp) so the closure-review tests can exercise the real
// generator. It is drawn once per handler in the constructor and never
// changes, which is what makes Stop -> Start an idempotent re-claim instead of
// a second producer.

// IO/control handler for one proxy device.
class UniversalAudioHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    UniversalAudioHandler(const std::string& deviceUID, uint32_t ownerUID,
                          const std::array<uint8_t, 16>& session)
        : shared_memory_(nullptr)
        , device_uid_(deviceUID)
        , owner_uid_(ownerUID)
        , session_(session)
        , io_client_count_(0)
        , state_(DeviceState::Uninitialized)
        , last_health_check_(std::chrono::steady_clock::now())
        , last_heartbeat_(std::chrono::steady_clock::now())
        , last_host_hb_(0)
        , last_host_hb_change_(std::chrono::steady_clock::now())
        , current_sample_rate_(DEFAULT_SAMPLE_RATE)
        , current_channels_(DEFAULT_CHANNELS)
        , resampler_(std::make_unique<SimpleResampler>(
            DEFAULT_SAMPLE_RATE, DEFAULT_SAMPLE_RATE, DEFAULT_CHANNELS))
    {
        std::string safe_uid = deviceUID;
        for (char& c : safe_uid) {
            if (c == ':' || c == '/' || c == ' ') c = '_';
        }
        // Mapping path identity (Batch 1): owner UID is part of the file name so
        // mappings of different users can never collide (was
        // /tmp/soundbridge-<uid>, a cross-user path clash risk). Must match
        // Host PathManager.sharedMemoryPath.
        shm_file_path_ = "/tmp/soundbridge-" + std::to_string(owner_uid_) + "-" + safe_uid;

        // Batch 2: this handler's claim identity for the admission gateway.
        // Fixed for the lifetime of the handler, so Stop -> Start re-claims
        // the same slot idempotently instead of creating a second producer.
        // 0 means generation failed; OnStartIO refuses to claim in that case.
        producer_token_ = soundbridge::GenerateProducerOwnerToken();

        RF_LOG_INFO("UniversalAudioHandler created: %s", device_uid_.c_str());
        RF_LOG_INFO("  Supports: 44.1-192kHz, 1-8ch, all formats");
    }

    ~UniversalAudioHandler() {
        RF_LOG_INFO("UniversalAudioHandler destructor: %s", device_uid_.c_str());
        // Batch 3: the destructor can only run once no HAL call is in flight
        // (Bridge::DoIOOperation holds a shared_ptr to the Device for the whole
        // call, and the Device owns this handler). Retire first anyway so the
        // mapping is dropped through the same drain path as every other
        // teardown, instead of relying on that argument being re-derived here.
        retired_.store(true, std::memory_order_release);
        Disconnect();
    }

    // Back-reference to the device for volume/mute sync on IO start
    void SetDevice(SoundBridgeDevice* device) { device_ = device; }

    // Set custom volume/mute controls for shared memory sync
    void SetVolumeControl(std::shared_ptr<SoundBridgeVolumeControl> vc) { volumeControl_ = std::move(vc); }
    void SetMuteControl(std::shared_ptr<SoundBridgeMuteControl> mc) { muteControl_ = std::move(mc); }

    // 移除代理并不保证已进入的 HAL 回调立即结束；永久拒绝该设备的新工作。
    void Retire() {
        retired_.store(true, std::memory_order_release);
        if (volumeControl_) volumeControl_->Retire();
        if (muteControl_) muteControl_->Retire();

        // Batch 3 / P0-A: device removal is the one teardown that does NOT pass
        // through OnStopIO, so nothing else would ever release this mapping.
        // io_mutex_ is taken only to stay mutually exclusive with OnStartIO and
        // OnStopIO (two concurrent retirees would race on mapping_owner_);
        // RetireMapping() does not take it, so there is no nested acquisition.
        std::lock_guard<std::mutex> lock(io_mutex_);
        RetireMapping("device-removed");
    }

    OSStatus OnStartIO() override {
        std::lock_guard<std::mutex> lock(io_mutex_);
        if (retired_.load(std::memory_order_acquire)) return kAudioHardwareUnspecifiedError;

        int32_t count = ++io_client_count_;
        stats_.client_starts++;

        RF_DebugLog("OnStartIO() client #%d (state: %s)", count, StateToString(state_.load()));
        RF_LOG_INFO("OnStartIO() client #%d (state: %s)", count, StateToString(state_.load()));

        if (count == 1) {
            state_ = DeviceState::Connecting;

            // Fail closed when the handler has no identity: rf_producer_claim()
            // rejects token 0 anyway, but the real reason must not be reported
            // as "mapping already owned". GenerateProducerOwnerToken() returns 0
            // only if its bounded retries were all exhausted, so this is not a
            // retryable condition.
            if (producer_token_ == 0) {
                RF_LOG_ERROR("OnStartIO: producer identity unavailable (token==0); refusing to claim");
                --io_client_count_;
                state_ = DeviceState::Error;
                return kAudioHardwareUnspecifiedError;
            }

            // Bounded retry loop. Worst case blocking is 150 ms, down from
            // the 17 250 ms the old 15-attempt exponential backoff accumulated.
            // See MAX_START_IO_ATTEMPTS / START_IO_BASE_DELAY_MS above.
            constexpr int MAX_ATTEMPTS = MAX_START_IO_ATTEMPTS;
            constexpr int BASE_DELAY_MS = START_IO_BASE_DELAY_MS;
            bool admission_refused = false;

            for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
                if (retired_.load(std::memory_order_acquire)) break;
                OpenSharedMemory();

                RFSharedAudio* mem = SharedMemory();
                if (mem) {
                    if (ValidateConnection() && !retired_.load(std::memory_order_acquire)) {
                        // Admission claim (Batch 2): the Host opened the
                        // mapping, but only ONE handler may produce into it.
                        // A refused claim is deterministic (another owner
                        // holds the slot), so retrying cannot help — fail
                        // closed and write nothing.
                        if (!rf_producer_claim(mem, producer_token_)) {
                            RF_LOG_ERROR("Admission refused: mapping already owned "
                                         "(state=%u owner=0x%llx token=0x%llx)",
                                rf_admission_state(mem),
                                (unsigned long long)rf_producer_owner_token(mem),
                                (unsigned long long)producer_token_);
                            admission_refused = true;
                            Disconnect();
                            break;
                        }
                        producer_claim_held_ = true;
                        // The owner token only proves "some handler"; the epoch
                        // proves "this mapping incarnation". Record what the
                        // Host published so every write is bound to it.
                        claimed_epoch_.store(rf_admission_epoch(mem),
                                             std::memory_order_relaxed);

                        RF_DebugLog("OnStartIO: Connected on attempt %d (uid=%s)", attempt, device_uid_.c_str());
                        RF_LOG_INFO("✓ Connected on attempt %d", attempt);
                        state_ = DeviceState::Connected;

                        // Pre-allocate conversion buffers
                        ResizeBuffers(mem);

                        // Prefill lifecycle (Batch 1): the driver NEVER pre-fills an
                        // ACTIVE mapping. The one-shot prefill moved to the Host side
                        // (SharedMemoryManager) and runs BEFORE the mapping is
                        // published, so Stop -> Start must not touch W/R again here.

                        last_heartbeat_ = std::chrono::steady_clock::now();

                        // Set shared memory pointer on custom volume/mute controls
                        // so they can sync changes to shared memory in real-time.
                        if (volumeControl_) {
                            volumeControl_->SetSharedMemory(mapping_owner_);
                            RF_DebugLog("OnStartIO: set shared memory on VolumeControl");
                        }
                        if (muteControl_) {
                            muteControl_->SetSharedMemory(mapping_owner_);
                            RF_DebugLog("OnStartIO: set shared memory on MuteControl");
                        }

                        // Volume state handshake (Phase 2.1).
                        //
                        // A rebuilt VolumeControl resets rawVolume_ to
                        // MaxRawVolume, i.e. scalar 1.0. Unconditionally syncing
                        // that into shared memory is exactly what made IO
                        // restarts jump to 100% (see POC_ERRATA M1 and the
                        // driver debug log evidence). Shared memory wins
                        // whenever the Host has already committed a state.
                        RF_DebugLog("OnStartIO: device_=%p", (void*)device_);
                        SyncVolumeStateWithSharedMemory(mem);

                        // Batch 3: admission opens last, once the mapping is
                        // published, validated, claimed, the buffers are sized
                        // and the controls are wired to this incarnation. A
                        // callback admitted earlier would race ResizeBuffers()
                        // and could write without a producer slot.
                        callback_gate_.Open();

                        return kAudioHardwareNoError;
                    } else {
                        RF_LOG_ERROR("✗ Validation failed");
                        Disconnect();
                    }
                }

                if (attempt < MAX_ATTEMPTS) {
                    const int delay = BASE_DELAY_MS * (1 << (attempt - 1));
                    RF_LOG_INFO("Retry %d/%d in %dms...", attempt + 1, MAX_ATTEMPTS, delay);
                    std::this_thread::sleep_for(std::chrono::milliseconds(delay));
                }
            }

            // All attempts failed. Report the reason once and give the caller a
            // proper error; HAL will retry when a client restarts IO.
            --io_client_count_;
            state_ = DeviceState::Error;
            if (admission_refused) {
                RF_LOG_ERROR("OnStartIO: producer admission refused — another producer owns this mapping");
                return kAudioHardwareUnspecifiedError;
            }
            RF_LOG_ERROR("OnStartIO: shared memory unavailable after %d attempt(s) (%d ms budget exhausted)",
                MAX_ATTEMPTS, START_IO_MAX_BLOCKING_MS);
            PrintDetailedError();
            return kAudioHardwareUnspecifiedError;
        }

        // Additional client path intentionally does no recovery work.
        return SharedMemory() ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
    }

    void OnStopIO() override {
        std::lock_guard<std::mutex> lock(io_mutex_);

        if (io_client_count_ == 0) {
            RF_LOG_ERROR("OnStopIO() called but count already 0!");
            return;
        }

        int32_t count = --io_client_count_;
        stats_.client_stops++;

        RF_LOG_INFO("OnStopIO() remaining: %d", count);

        if (count == 0) {
            RF_LOG_INFO("Last client stopped - disconnecting");
            // Release the producer slot BEFORE retiring the mapping.
            //
            // Two independent arguments hold here, and both are needed:
            // OnStopIO holds libASPL's per-device ioMutex_, and DoIOOperation
            // takes the same lock, so no callback can be running right now;
            // and Disconnect() below retires the mapping through
            // RetireMapping(), which proves no admitted callback is left before
            // anything is unmapped. The destructor and device removal only
            // have the second argument, which is why ownership is not released
            // on those paths.
            RFSharedAudio* mem = SharedMemory();
            if (mem && producer_claim_held_) {
                rf_producer_release(mem, producer_token_);
                producer_claim_held_ = false;
            }
            Disconnect();
            state_ = DeviceState::Disconnected;
        }
    }

    void OnWriteMixedOutput(
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        stats_.total_writes++;

        // Admission (Batch 3). A callback that arrives after retirement, or
        // before a mapping is published, is refused here and never loads the
        // mapping pointer at all.
        if (retired_.load(std::memory_order_acquire) || !callback_gate_.TryEnter()) {
            stats_.failed_writes++;
            return;
        }
        // Every return below leaves through this destructor, so an early exit
        // can never leave the admission counter incremented (which would make
        // the drain wait for a callback that is already gone).
        CallbackLease lease(callback_gate_);

        // One load for the whole callback. The retiring thread cannot unmap
        // this mapping while the lease is held, and it closes the gate before
        // it clears the pointer, so a non-null value here is stable.
        RFSharedAudio* mem = SharedMemory();
        if (!mem) {
            stats_.failed_writes++;
            return;
        }

        // Keep callback RT-safe: avoid filesystem checks/recovery here.
        rf_update_driver_heartbeat(mem);

        // Get stream format
        AudioStreamBasicDescription fmt = stream->GetPhysicalFormat();

        if (fmt.mBytesPerFrame == 0) {
            stats_.failed_writes++;
            return;
        }

        UInt32 frameCount = bytesCount / fmt.mBytesPerFrame;
        if (frameCount == 0) {
            stats_.failed_writes++;
            return;
        }

        // Check if format change is needed
        if (fmt.mSampleRate != current_sample_rate_ ||
            fmt.mChannelsPerFrame != current_channels_) {

            RF_LOG_INFO("Format change: %.0fHz %uch -> %uHz %uch",
                fmt.mSampleRate, fmt.mChannelsPerFrame,
                current_sample_rate_, current_channels_);

            HandleFormatChange(mem, fmt);
        }

        // Ensure pre-allocated buffer is large enough
        size_t needed = frameCount * fmt.mChannelsPerFrame;
        if (interleaved_buf_.size() < needed) {
            interleaved_buf_.resize(needed);
        }

        // Convert to interleaved float32 using pre-allocated buffer
        if (!ConvertToFloat32Interleaved(bytes, frameCount, fmt, interleaved_buf_)) {
            stats_.failed_writes++;
            return;
        }

        // Compensate callback timestamp discontinuities (gaps/overlaps) to keep
        // a continuous producer timeline for the host reader.
        uint32_t skip_frames = 0;
        uint32_t prepend_silence_frames = 0;
        if (has_last_output_timestamp_) {
            const double delta = timestamp - last_output_timestamp_end_;
            if (delta > 0.5) {
                prepend_silence_frames = static_cast<uint32_t>(
                    std::min<double>(delta, mem->ring_capacity_frames / 2.0));
            } else if (delta < -0.5) {
                skip_frames = static_cast<uint32_t>(std::min<double>(-delta, frameCount));
            }
        }
        has_last_output_timestamp_ = true;
        last_output_timestamp_end_ = timestamp + frameCount;

        // Handle sample rate conversion if needed
        if (fmt.mSampleRate != mem->sample_rate) {
            const float* payload = interleaved_buf_.data() + (skip_frames * fmt.mChannelsPerFrame);
            const uint32_t payload_frames = frameCount - skip_frames;
            if (payload_frames > 0) {
                ProcessWithSampleRateConversion(mem, payload, payload_frames,
                                            fmt.mSampleRate, mem->sample_rate,
                                            fmt.mChannelsPerFrame);
            }
        } else {
            if (prepend_silence_frames > 0) {
                const size_t available_silence_frames =
                    silence_buf_.size() / fmt.mChannelsPerFrame;
                if (prepend_silence_frames > available_silence_frames) {
                    prepend_silence_frames = static_cast<uint32_t>(available_silence_frames);
                }
                const size_t silence_needed = prepend_silence_frames * fmt.mChannelsPerFrame;
                std::fill_n(silence_buf_.begin(), silence_needed, 0.0f);
                WriteWithAdaptiveDriftCompensation(mem, silence_buf_.data(), prepend_silence_frames,
                                                   fmt.mSampleRate, fmt.mChannelsPerFrame);
            }

            const float* payload = interleaved_buf_.data() + (skip_frames * fmt.mChannelsPerFrame);
            const uint32_t payload_frames = frameCount - skip_frames;
            if (payload_frames > 0) {
                WriteWithAdaptiveDriftCompensation(mem, payload, payload_frames,
                                               fmt.mSampleRate, fmt.mChannelsPerFrame);
            }
        }

        stats_.LogPeriodic();
    }

    // Keep proxy volume controls for UI/events, but avoid applying proxy gain in-driver.
    // Volume is forwarded to the physical output device by the host process.
    void OnProcessMixedOutput(
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        (void)stream;
        (void)zeroTimestamp;
        (void)timestamp;
        (void)frames;
        (void)frameCount;
        (void)channelCount;
    }

private:
    // ===== Mapping retirement (Batch 3) =====
    //
    // How long a retire may wait for admitted callbacks to leave before the
    // mapping is quarantined instead of unmapped. This is a deadlock guard for
    // the control thread, never a safety mechanism: only the admission counter
    // reaching zero yields Drained.
    static constexpr std::chrono::milliseconds kRetireDrainBudget{250};

    // The mapping a callback may touch, or nullptr. Every access goes through
    // this accessor; the raw member is never dereferenced directly.
    RFSharedAudio* SharedMemory() const noexcept {
        return shared_memory_.load(std::memory_order_acquire);
    }

    // RAII admission ticket. A callback must not be able to skip Leave() on an
    // early return: a leaked admission would make CloseAndDrain() wait for a
    // callback that has already left, and a healthy mapping would be quarantined
    // for no reason.
    struct CallbackLease {
        explicit CallbackLease(soundbridge::CallbackGate& gate) noexcept : gate_(gate) {}
        ~CallbackLease() { gate_.Leave(); }
        CallbackLease(const CallbackLease&) = delete;
        CallbackLease& operator=(const CallbackLease&) = delete;
    private:
        soundbridge::CallbackGate& gate_;
    };

    // Retire the published mapping incarnation: close admission, wait for
    // admitted callbacks to leave, then unmap (provable) or quarantine (not).
    //
    // Never called from a realtime thread. Callers are OnStopIO (through
    // Disconnect), Retire() (device removal), the destructor, and
    // OpenSharedMemory() as a defensive guard.
    //
    // Sequencing matters: the pointer is cleared AFTER the drain attempt, so a
    // callback that is still inside keeps a valid `mem` for its whole body
    // while no new callback can obtain one; and it is cleared BEFORE
    // mapping_owner_ is released, so the munmap is never observable through the
    // pointer.
    soundbridge::DrainAck RetireMapping(const char* reason,
                                        std::chrono::milliseconds budget = kRetireDrainBudget) {
        const uint64_t revision = mapping_revision_.load(std::memory_order_acquire);
        const uint64_t epoch = claimed_epoch_.load(std::memory_order_relaxed);

        if (SharedMemory() == nullptr) {
            // Nothing published. Close anyway: this is what makes a callback
            // arriving between "pointer cleared" and "next start" fail closed.
            callback_gate_.Close();
            return soundbridge::DrainAck{revision, epoch,
                                         soundbridge::DrainOutcome::NothingToRetire};
        }

        const auto deadline = std::chrono::steady_clock::now() + budget;
        const soundbridge::DrainAck ack =
            callback_gate_.CloseAndDrain(revision, epoch, deadline);

        shared_memory_.store(nullptr, std::memory_order_release);
        shared_memory_size_ = 0;

        if (ack.Drained()) {
            mapping_owner_.reset();  // munmap
            RF_LOG_INFO("Mapping retired: revision %llu epoch %llu (%s)",
                (unsigned long long)revision, (unsigned long long)epoch, reason ? reason : "");
        } else {
            // Not provable -> do not munmap. The page stays mapped for the life
            // of the process, so a callback we could not observe cannot fault
            // on it. Virtual address space is the cheap side of this trade.
            RF_LOG_ERROR("Mapping retirement NOT proven (%s): revision %llu epoch %llu, "
                         "%d callback(s) still admitted; quarantining instead of munmap",
                reason ? reason : "", (unsigned long long)revision, (unsigned long long)epoch,
                (int)callback_gate_.ActiveCount());
            soundbridge::MappingQuarantine::Retain(std::move(mapping_owner_), revision, epoch,
                                                   reason);
        }

        return ack;
    }

    // ===== Volume state handshake (Phase 2.1) =====
    //
    // Decides who owns the volume state at IO start:
    //
    //   committed state exists (state_initialized == 1)
    //       -> shared memory wins. Push it INTO the controls, because a
    //          freshly constructed VolumeControl sits at MaxRawVolume
    //          (scalar 1.0) and would otherwise report 100% to every HAL
    //          client while the Host renders at the real gain.
    //
    //   no committed state (state_initialized == 0)
    //       -> bootstrap. The controls carry whatever the Host applied via
    //          setDeviceVolume() before IO started, so seed shared memory
    //          from them through rf_publish_volume_state(), which also
    //          latches state_initialized and bumps the revision once.
    void SyncVolumeStateWithSharedMemory(RFSharedAudio* mem) {
        if (!mem) return;

        const float control_scalar = volumeControl_ ? volumeControl_->GetScalarValue() : 0.35f;
        const bool control_muted = muteControl_ ? muteControl_->GetIsMuted() : false;

        RFVolumeStateSnapshot snapshot{};
        const RFVolumeSyncOutcome outcome = rf_sync_driver_volume_state(
            mem, control_scalar, control_muted, &snapshot);

        switch (outcome) {
            case RF_VOLUME_SYNC_ADOPTED:
                RF_LOG_INFO("Volume state: adopted committed shared-memory value %.4f (rev %llu)",
                    snapshot.scalar, (unsigned long long)snapshot.revision);
                RF_DebugLog("OnStartIO: committed state found: scalar=%.4f muted=%d mode=%u rev=%llu",
                    snapshot.scalar, snapshot.muted, snapshot.mode,
                    (unsigned long long)snapshot.revision);
                break;

            case RF_VOLUME_SYNC_SEEDED:
                RF_LOG_INFO("Volume state: first-time bootstrap from controls (scalar=%.4f, muted=%d, rev %llu)",
                    snapshot.scalar, snapshot.muted, (unsigned long long)snapshot.revision);
                RF_DebugLog("OnStartIO: bootstrapped volume state: scalar=%.4f muted=%d rev=%llu",
                    snapshot.scalar, snapshot.muted, (unsigned long long)snapshot.revision);
                break;

            case RF_VOLUME_SYNC_REJECTED:
            default:
                // ValidateConnection owns the protocol-mismatch report; do not
                // touch a block we cannot reason about.
                RF_LOG_ERROR("Volume state: shared memory rejected (%s); controls left untouched",
                    rf_validate_result_string(rf_validate_header(mem)));
                return;
        }

        // A rebuilt VolumeControl sits at MaxRawVolume (scalar 1.0), so both
        // outcomes end by pushing the authoritative value INTO the controls.
        if (volumeControl_) {
            OSStatus status = volumeControl_->RestoreFromSharedMemory(snapshot.scalar);
            RF_DebugLog("OnStartIO: pushed %.4f into VolumeControl (status=%d)",
                snapshot.scalar, (int)status);
        }
        if (muteControl_) {
            OSStatus status = muteControl_->RestoreFromSharedMemory(snapshot.muted != 0);
            RF_DebugLog("OnStartIO: pushed muted=%d into MuteControl (status=%d)",
                snapshot.muted, (int)status);
        }
    }

    void OpenSharedMemory() {
        RF_DebugLog("OpenSharedMemory: %s", shm_file_path_.c_str());
        RF_LOG_INFO("Opening: %s", shm_file_path_.c_str());

        // Batch 3: a mapping published earlier in this handler's life must be
        // retired through the gate before its address range is replaced. This
        // is defence in depth -- OnStartIO reaches here only after Disconnect()
        // -- but it makes "publish" never overwrite a live incarnation.
        if (SharedMemory()) RetireMapping("reopen");

        if (HostLockStatus(owner_uid_, session_) != soundbridge::LockStatus::held) return;
        const int fd = open(shm_file_path_.c_str(), O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) return;
        struct stat st{}, current{};
        const bool validFile = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == owner_uid_ &&
            st.st_size >= static_cast<off_t>(sizeof(RFSharedAudio)) && st.st_size <= 64 * 1024 * 1024 &&
            lstat(shm_file_path_.c_str(), &current) == 0 && st.st_dev == current.st_dev && st.st_ino == current.st_ino;
        if (!validFile) {
            close(fd);
            return;
        }
        const size_t length = static_cast<size_t>(st.st_size);
        void* mem = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (mem == MAP_FAILED) return;
        auto* candidate = reinterpret_cast<RFSharedAudio*>(mem);
        if (!soundbridge::validateSharedMemory(candidate, length, session_) ||
            HostLockStatus(owner_uid_, session_) != soundbridge::LockStatus::held ||
            lstat(shm_file_path_.c_str(), &current) != 0 || st.st_dev != current.st_dev || st.st_ino != current.st_ino) {
            munmap(mem, length);
            return;
        }
        mapping_owner_ = std::make_shared<soundbridge::SharedMemoryMapping>(candidate, length);
        shared_memory_size_ = length;

        RF_DebugLog("OpenSharedMemory: mapped %p size=%lld rate=%u ch=%u fmt=%u",
            mem, (long long)st.st_size, candidate->sample_rate, candidate->channels, candidate->format);
        RF_LOG_INFO("✓ Mapped at %p (size: %lld)", mem, (long long)st.st_size);
        RF_LOG_INFO("  Format: %uHz, %uch, format=%u",
            candidate->sample_rate,
            candidate->channels,
            candidate->format);

        current_sample_rate_ = candidate->sample_rate;
        current_channels_ = candidate->channels;

        // Publish (Batch 3). The revision advances before the pointer becomes
        // visible, so when a later retire reads the revision it necessarily
        // sees this incarnation's stamp; an ACK produced for an earlier one
        // carries a lower revision and can never be mistaken for this one.
        mapping_revision_.fetch_add(1, std::memory_order_acq_rel);
        shared_memory_.store(candidate, std::memory_order_release);
    }

    void Disconnect() {
        // 先停止发布新租约，已进入的控件回调会保留旧映射直至结束。
        if (volumeControl_) {
            volumeControl_->SetSharedMemory(nullptr);
        }
        if (muteControl_) {
            muteControl_->SetSharedMemory(nullptr);
        }

        if (RFSharedAudio* mem = SharedMemory()) {
            RF_LOG_INFO("Disconnecting: %s", device_uid_.c_str());

            // Mark as disconnected
            atomic_store(&mem->driver_connected, 0);
        }

        // Batch 3: one retirement path for every caller. Reached from OnStopIO
        // the drain is already implied by libASPL's ioMutex_ (no callback can
        // run while StopIO holds it); reached from Retire()/the destructor that
        // argument is unavailable, so the gate has to prove it instead.
        RetireMapping("disconnect");

        if (resampler_) {
            resampler_->Reset();
        }
    }

    bool ValidateConnection() {
        RFSharedAudio* mem = SharedMemory();
        if (!mem) return false;

        // One implementation of the connection contract, shared with the Host
        // test suite through RFSharedAudio.h. Do not duplicate these checks
        // here: a second copy is how the driver and the Host end up disagreeing
        // about what a valid header looks like.
        if (!soundbridge::validateSharedMemory(mem, shared_memory_size_, session_) ||
            HostLockStatus(owner_uid_, session_) != soundbridge::LockStatus::held) return false;
        const RFValidateResult result = rf_validate_header(mem);
        if (result != RF_VALIDATE_OK) {
            RF_DebugLog("ValidateConnection: rejected (%s) protocol=0x%x header_size=%u rate=%u channels=%u",
                rf_validate_result_string(result),
                mem->protocol_version,
                mem->header_size,
                mem->sample_rate,
                mem->channels);
            RF_LOG_ERROR("Connection rejected: %s (protocol=0x%x header_size=%u rate=%u ch=%u)",
                rf_validate_result_string(result),
                mem->protocol_version,
                mem->header_size,
                mem->sample_rate,
                mem->channels);
            return false;
        }

        // Mark driver as connected
        atomic_store(&mem->driver_connected, 1);
        RF_DebugLog("ValidateConnection: OK (driver_connected=1, state_initialized=%u, revision=%llu)",
            atomic_load(&mem->state_initialized),
            (unsigned long long)rf_get_state_revision(mem));

        return true;
    }

    bool IsHealthy() {
        RFSharedAudio* mem = SharedMemory();
        if (!mem) return false;

        // Check file existence
        struct stat st;
        if (stat(shm_file_path_.c_str(), &st) != 0) {
            RF_LOG_ERROR("Health: file vanished");
            return false;
        }

        // Check host connection
        uint32_t host_conn = atomic_load(&mem->host_connected);
        if (host_conn == 0) {
            RF_LOG_ERROR("Health: host disconnected");
            return false;
        }

        // Check heartbeat timeout (treat a never-started heartbeat as unhealthy after timeout)
        auto now = std::chrono::steady_clock::now();
        uint64_t current_host_hb = atomic_load(&mem->host_heartbeat);

        if (current_host_hb != last_host_hb_) {
            last_host_hb_ = current_host_hb;
            last_host_hb_change_ = now;
        } else {
            auto hb_age = std::chrono::duration_cast<std::chrono::seconds>(
                now - last_host_hb_change_).count();
            if (hb_age >= HEARTBEAT_TIMEOUT_SEC) {
                RF_LOG_ERROR("Health: host heartbeat timeout (stalled %llds)", (long long)hb_age);
                return false;
            }
        }

        // Check ring buffer integrity
        uint64_t write_idx = atomic_load(&mem->write_index);
        uint64_t read_idx = atomic_load(&mem->read_index);

        if (write_idx < read_idx) {
            RF_LOG_ERROR("Health: corruption (write < read)");
            return false;
        }

        uint64_t used = write_idx - read_idx;
        if (used > mem->ring_capacity_frames) {
            RF_LOG_ERROR("Health: overflow (used > capacity)");
            return false;
        }

        return true;
    }

    void AttemptRecovery() {
        RF_LOG_INFO("Attempting recovery...");
        stats_.reconnections++;

        Disconnect();

        if (io_client_count_ > 0) {
            OpenSharedMemory();
            RFSharedAudio* mem = SharedMemory();
            if (mem && ValidateConnection()) {
                RF_LOG_INFO("✓ Recovery successful");
                state_ = DeviceState::Connected;
            } else {
                RF_LOG_ERROR("✗ Recovery failed");
                state_ = DeviceState::Error;
            }
        }
    }

    void ResizeBuffers(RFSharedAudio* mem) {
        if (!mem) return;

        // Size for max expected callback: 4096 frames at 192kHz, 8 channels
        uint32_t max_frames = 4096;
        uint32_t max_channels = RF_MAX_CHANNELS;

        interleaved_buf_.resize(max_frames * max_channels);
        resampled_buf_.resize(max_frames * 2 * max_channels); // 2x for upsampling headroom
        const uint32_t max_silence_frames = std::max<uint32_t>(
            1, mem->ring_capacity_frames / 2);
        silence_buf_.resize(max_silence_frames * max_channels, 0.0f);
    }

    void HandleFormatChange(RFSharedAudio* mem, const AudioStreamBasicDescription& new_fmt) {
        stats_.format_changes++;

        current_sample_rate_ = (uint32_t)new_fmt.mSampleRate;
        current_channels_ = new_fmt.mChannelsPerFrame;

        if (mem && resampler_) {
            resampler_->SetChannels(new_fmt.mChannelsPerFrame);
            resampler_->SetRates(new_fmt.mSampleRate, mem->sample_rate);
            RF_LOG_INFO("Configured resampler: %.0f -> %u Hz",
                new_fmt.mSampleRate, mem->sample_rate);
        }

        ResizeBuffers(mem);
    }

    bool ConvertToFloat32Interleaved(const void* bytes, UInt32 frameCount,
                                     const AudioStreamBasicDescription& fmt,
                                     std::vector<float>& output) {
        output.resize(frameCount * fmt.mChannelsPerFrame);

        if (fmt.mFormatFlags & kAudioFormatFlagIsFloat) {
            // Fail-closed (Batch 1): only 32-bit float is the canonical ring
            // format. Float64 or any other float bit depth must never be
            // reinterpreted as Float32 and written into the ring.
            if (fmt.mBitsPerChannel != 32) {
                RF_LOG_ERROR("Unsupported float bit depth %u (Float32 only)", fmt.mBitsPerChannel);
                return false;
            }
            const float* input = static_cast<const float*>(bytes);
            if (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
                // Non-interleaved to interleaved
                for (UInt32 ch = 0; ch < fmt.mChannelsPerFrame; ch++) {
                    const float* channel = input + (ch * frameCount);
                    for (UInt32 i = 0; i < frameCount; i++) {
                        output[i * fmt.mChannelsPerFrame + ch] = channel[i];
                    }
                }
            } else {
                // Already interleaved
                std::memcpy(output.data(), input, frameCount * fmt.mChannelsPerFrame * sizeof(float));
            }
        } else if (fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
            if (fmt.mBitsPerChannel == 16) {
                const int16_t* input = static_cast<const int16_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    output[i] = (float)input[i] / 32768.0f;
                }
            } else if (fmt.mBitsPerChannel == 32) {
                const int32_t* input = static_cast<const int32_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    output[i] = (float)input[i] / 2147483648.0f;
                }
            } else if (fmt.mBitsPerChannel == 24) {
                const uint8_t* input = static_cast<const uint8_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    int32_t val = (int32_t)((input[i*3] << 0) | (input[i*3+1] << 8) | (input[i*3+2] << 16));
                    if (val & 0x800000) val |= 0xFF000000;  // Sign extend
                    output[i] = (float)val / 8388608.0f;
                }
            } else {
                return false;
            }
        } else {
            RF_LOG_ERROR("Unsupported format flags: 0x%x", fmt.mFormatFlags);
            return false;
        }

        return true;
    }

    // `mem` is the incarnation the caller was admitted for. Passing it in
    // instead of re-reading shared_memory_ keeps the whole write bound to one
    // mapping even if the pointer is cleared concurrently (Batch 3).
    void ProcessWithSampleRateConversion(RFSharedAudio* mem,
                                        const float* input, uint32_t input_frames,
                                        double input_rate, double output_rate,
                                        uint32_t channels) {
        if (!resampler_ || !mem) return;
        resampler_->SetChannels(channels);
        resampler_->SetRates(input_rate, output_rate);

        stats_.sample_rate_conversions++;

        // Calculate output size and ensure buffer is large enough
        uint32_t output_capacity =
            static_cast<uint32_t>((input_frames * output_rate) / input_rate) + 10;
        size_t needed = output_capacity * channels;
        if (resampled_buf_.size() < needed) {
            resampled_buf_.resize(needed);
        }

        uint32_t output_frames = resampler_->Process(
            input, input_frames,
            resampled_buf_.data(), output_capacity);

        if (output_frames > 0) {
            uint32_t dropped = 0;
            rf_ring_write(mem, resampled_buf_.data(), output_frames, producer_token_,
                          claimed_epoch_.load(std::memory_order_relaxed), &dropped);
        }
    }

    void WriteWithAdaptiveDriftCompensation(RFSharedAudio* mem,
                                            const float* input,
                                            uint32_t input_frames,
                                            double sample_rate,
                                            uint32_t channels) {
        if (!mem) return;

        const uint64_t write_idx = atomic_load(&mem->write_index);
        const uint64_t read_idx = atomic_load(&mem->read_index);
        const uint32_t capacity = mem->ring_capacity_frames;
        const uint64_t used = write_idx - read_idx;

        if (capacity == 0) {
            // Fail-closed path: rf_ring_write rejects a zero/non-power-of-two
            // capacity internally as well; nothing may be written to a corrupt ring.
            uint32_t dropped = 0;
            rf_ring_write(mem, input, input_frames, producer_token_,
                          claimed_epoch_.load(std::memory_order_relaxed), &dropped);
            return;
        }

        const int64_t target_fill = static_cast<int64_t>(capacity / ADAPTIVE_FILL_TARGET_DIVISOR);
        const int64_t error = target_fill - static_cast<int64_t>(used);
        const int64_t deadband = std::max<int64_t>(1,
            (capacity * ADAPTIVE_FILL_DEADBAND_PERCENT) / 100);

        // Within deadband, keep exact nominal rate and avoid extra SRC work.
        if (std::llabs(error) <= deadband) {
            uint32_t dropped = 0;
            rf_ring_write(mem, input, input_frames, producer_token_,
                          claimed_epoch_.load(std::memory_order_relaxed), &dropped);
            return;
        }

        // Small adaptive ratio correction to keep producer/consumer clocks centered.
        const double normalized_error =
            static_cast<double>(error) / std::max<int64_t>(1, target_fill);
        const double ppm_adjust =
            std::clamp(normalized_error * ADAPTIVE_MAX_ADJUST_PPM,
                       -ADAPTIVE_MAX_ADJUST_PPM, ADAPTIVE_MAX_ADJUST_PPM);
        const double adjusted_output_rate = sample_rate * (1.0 + (ppm_adjust / 1'000'000.0));

        ProcessWithSampleRateConversion(mem, input, input_frames, sample_rate,
                                        adjusted_output_rate, channels);
    }

    void PrintDetailedError() {
        RF_LOG_ERROR("╔════════════════════════════════════════════════╗");
        RF_LOG_ERROR("║          OnStartIO FAILED - CRITICAL           ║");
        RF_LOG_ERROR("╚════════════════════════════════════════════════╝");
        RF_LOG_ERROR("Device: %s", device_uid_.c_str());
        RF_LOG_ERROR("File: %s", shm_file_path_.c_str());
        RF_LOG_ERROR("");
        RF_LOG_ERROR("Troubleshooting:");
        RF_LOG_ERROR("  1. Is host application running?");
        RF_LOG_ERROR("  2. Check: ls -la /tmp/soundbridge-*");
        RF_LOG_ERROR("  3. Check: cat /tmp/soundbridge-devices.txt");
        RF_LOG_ERROR("  4. Try: sudo killall coreaudiod");
        RF_LOG_ERROR("  5. Check logs: log show --predicate 'subsystem == \"com.soundbridge.driver\"'");
    }

private:
    // ===== Mapping lifetime (Batch 3) =====
    //
    // shared_memory_ is atomic because the realtime write callback reads it
    // while StopIO, device removal and the destructor clear it. Atomicity only
    // makes the pointer read well defined; what makes the unmap safe is that
    // every realtime access happens inside an admitted callback and the
    // retiring thread unmaps only after the gate proved every admitted callback
    // left. See RetireMapping().
    //
    // libASPL 的 Device::ioMutex_ 仍然串行化 StartIO、StopIO 与 DoIOOperation，但
    // Retire() 的设备移除路径和析构路径不走那个锁，所以不能依赖它。
    std::atomic<RFSharedAudio*> shared_memory_{nullptr};
    std::shared_ptr<soundbridge::SharedMemoryMapping> mapping_owner_;

    // The only authority on "a callback may touch the mapping". Starts closed.
    soundbridge::CallbackGate callback_gate_;

    // Monotonic, per-handler stamp assigned every time a mapping is published.
    // A drain ACK carries the revision it was produced for, so an ACK from an
    // older incarnation can never be applied to a newer one.
    std::atomic<uint64_t> mapping_revision_{0};
    SoundBridgeDevice* device_ = nullptr;  // back-reference for volume sync on IO start
    std::shared_ptr<SoundBridgeVolumeControl> volumeControl_;
    std::shared_ptr<SoundBridgeMuteControl> muteControl_;
    std::string device_uid_;
    uint32_t owner_uid_;
    std::array<uint8_t, 16> session_;
    size_t shared_memory_size_ = 0;
    std::string shm_file_path_;

    // Admission gateway identity (Batch 2). Written once under io_mutex_ in
    // OnStartIO and read by the realtime path, which is why producer_token_ is
    // a plain member: it never changes after construction. The claimed epoch
    // does change (once per start) and is read from the render thread, so it is
    // an atomic relaxed pair — same cost as a plain load, TSan-clean.
    uint64_t producer_token_ = 0;
    bool producer_claim_held_ = false;
    std::atomic<uint64_t> claimed_epoch_{0};

    std::atomic<int32_t> io_client_count_;
    std::atomic<bool> retired_{false};
    std::mutex io_mutex_;

    std::atomic<DeviceState> state_;

    std::chrono::steady_clock::time_point last_health_check_;
    std::chrono::steady_clock::time_point last_heartbeat_;
    uint64_t last_host_hb_;
    std::chrono::steady_clock::time_point last_host_hb_change_;

    uint32_t current_sample_rate_;
    uint32_t current_channels_;

    std::unique_ptr<SimpleResampler> resampler_;

    // Pre-allocated buffers to avoid heap allocation on the audio thread
    std::vector<float> interleaved_buf_;
    std::vector<float> resampled_buf_;
    std::vector<float> silence_buf_;

    bool has_last_output_timestamp_{false};
    double last_output_timestamp_end_{0.0};

    AudioStats stats_;
};

// Global state
struct SoundBridgeGlobalState {
    std::shared_ptr<aspl::Context> context;
    std::shared_ptr<aspl::Plugin> plugin;
    std::shared_ptr<aspl::Driver> driver;
    std::mutex sync_mutex;
    soundbridge::SessionTracker session;
    std::map<std::string, std::shared_ptr<aspl::Device>> devices;
    std::thread monitor_thread;
    std::atomic<bool> should_stop{false};

    struct HostHeartbeatState {
        uint64_t last_value{0};
        bool observed{false};
        std::chrono::steady_clock::time_point last_change{std::chrono::steady_clock::now()};
    };
    std::map<std::string, HostHeartbeatState> host_hb_cache;

    // Track when devices were removed to prevent rapid cycling
    std::map<std::string, std::chrono::steady_clock::time_point> device_removal_times;
};

static SoundBridgeGlobalState* g_state = nullptr;

std::shared_ptr<aspl::Device> CreateProxyDevice(const std::string& name, const std::string& uid,
                                                const soundbridge::ControlSnapshot& session) {
    if (!g_state) return nullptr;

    aspl::DeviceParameters params;
    params.Name = name + " (SoundBridge)";
    params.DeviceUID = uid + "-soundbridge";
    params.Manufacturer = "SoundBridge";
    params.SampleRate = DEFAULT_SAMPLE_RATE;
    params.ChannelCount = DEFAULT_CHANNELS;
    params.EnableMixing = true;
    params.ZeroTimeStampPeriod = HAL_ZERO_TIMESTAMP_PERIOD_FRAMES;
    params.SafetyOffset = HAL_SAFETY_OFFSET_FRAMES;
    params.Latency = HAL_PRESENTATION_LATENCY_FRAMES;

    auto device = std::make_shared<SoundBridgeDevice>(g_state->context, params);

    // Create stream manually instead of using AddStreamWithControlsAsync
    auto stream = device->AddStreamAsync(aspl::Direction::Output);

    // Create custom VolumeControl and MuteControl that sync to shared memory.
    //
    // The taper is 48 dB over 48 raw steps, matching RF_VOLUME_* in
    // RFSharedAudio.h and VolumeTaper on the Host. libASPL keeps its Pow2
    // transfer function because the dB range exceeds 30 dB, so both sides end
    // up on dB = 48 * sqrt(scalar) - 48.
    aspl::VolumeControlParameters volumeParams;
    volumeParams.MinRawVolume = VOLUME_RAW_MIN;
    volumeParams.MaxRawVolume = VOLUME_RAW_MAX;
    volumeParams.MinDecibelVolume = VOLUME_DB_MIN;
    volumeParams.MaxDecibelVolume = VOLUME_DB_MAX;
    auto volumeControl = std::make_shared<SoundBridgeVolumeControl>(
        g_state->context, volumeParams);
    auto muteControl = std::make_shared<SoundBridgeMuteControl>(
        g_state->context, aspl::MuteControlParameters{});

    // Add controls to device
    device->AddVolumeControlAsync(volumeControl);
    device->AddMuteControlAsync(muteControl);

    // Attach controls to stream
    stream->AttachVolumeControl(volumeControl);
    stream->AttachMuteControl(muteControl);

    auto handler = std::make_shared<UniversalAudioHandler>(uid, session.ownerUID, session.session);
    handler->SetVolumeControl(volumeControl);
    handler->SetMuteControl(muteControl);
    handler->SetDevice(device.get());
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    RF_LOG_INFO("✓ Device created: %s", params.Name.c_str());

    return device;
}

void AddDevice(const std::string& name, const std::string& uid,
               const soundbridge::ControlSnapshot& session) {
    if (!g_state || g_state->devices.find(uid) != g_state->devices.end()) return;

    auto device = CreateProxyDevice(name, uid, session);
    if (device) {
        g_state->plugin->AddDevice(device);
        g_state->devices[uid] = device;
        // Preserve any stale heartbeat knowledge; only init if missing.
        if (g_state->host_hb_cache.find(uid) == g_state->host_hb_cache.end()) {
            g_state->host_hb_cache[uid] = SoundBridgeGlobalState::HostHeartbeatState{};
        }
    }
}

void RemoveDevice(const std::string& uid) {
    if (!g_state) return;

    auto it = g_state->devices.find(uid);
    if (it != g_state->devices.end()) {
        if (auto* handler = dynamic_cast<UniversalAudioHandler*>(it->second->GetControlHandler())) {
            handler->Retire();
        }
        g_state->plugin->RemoveDevice(it->second);
        g_state->devices.erase(it);
        // Track removal time for cooldown
        g_state->device_removal_times[uid] = std::chrono::steady_clock::now();
    }
}

bool IsDeviceInCooldown(const std::string& uid) {
    if (!g_state) return false;

    auto it = g_state->device_removal_times.find(uid);
    if (it == g_state->device_removal_times.end()) {
        return false;
    }

    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - it->second).count();

    return elapsed < DEVICE_COOLDOWN_SEC;
}

/// 路径规则必须与 Host 的 PathManager 保持一致（含 ownerUID 前缀）。
static std::string SharedMemoryPath(const std::string& uid, uint32_t ownerUID) {
    std::string safe_uid = uid;
    for (char& c : safe_uid) {
        if (c == ':' || c == '/' || c == ' ') c = '_';
    }
    return "/tmp/soundbridge-" + std::to_string(ownerUID) + "-" + safe_uid;
}

using soundbridge::HeartbeatStatus;

// 缺失、不可读或会话不匹配的映射只是未知，不是有效空集合。
static HeartbeatStatus HostHeartbeatStatus(const std::string& uid,
                                           const soundbridge::ControlSnapshot& session) {
    const std::string path = SharedMemoryPath(uid, session.ownerUID);
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return HeartbeatStatus::pending;
    struct stat st{}, current{};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != session.ownerUID ||
        st.st_size < static_cast<off_t>(sizeof(RFSharedAudio)) || st.st_size > 64 * 1024 * 1024 ||
        lstat(path.c_str(), &current) != 0 || st.st_dev != current.st_dev || st.st_ino != current.st_ino) {
        close(fd);
        return HeartbeatStatus::pending;
    }
    void* mem = mmap(nullptr, sizeof(RFSharedAudio), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (mem == MAP_FAILED) return HeartbeatStatus::pending;
    const auto* shared = reinterpret_cast<const RFSharedAudio*>(mem);
    const bool valid = soundbridge::validateSharedMemory(shared, static_cast<size_t>(st.st_size), session.session);
    const uint64_t hb = valid ? atomic_load(&shared->host_heartbeat) : 0;
    const bool connected = valid && atomic_load(&shared->host_connected) != 0;
    munmap(mem, sizeof(RFSharedAudio));
    if (!valid || lstat(path.c_str(), &current) != 0 || st.st_dev != current.st_dev || st.st_ino != current.st_ino)
        return HeartbeatStatus::pending;

    auto& state = g_state->host_hb_cache[uid];
    const auto now = std::chrono::steady_clock::now();
    if (!state.observed || hb != state.last_value) {
        state.observed = true;
        state.last_value = hb;
        state.last_change = now;
    }
    const auto age = std::chrono::duration_cast<std::chrono::seconds>(now - state.last_change).count();
    if (age >= HEARTBEAT_TIMEOUT_SEC) return HeartbeatStatus::stale;
    return connected && hb != 0 ? HeartbeatStatus::fresh : HeartbeatStatus::pending;
}

static void RemoveAllSessionDevices() {
    std::vector<std::string> uids;
    for (const auto& entry : g_state->devices) uids.push_back(entry.first);
    for (const auto& uid : uids) RemoveDevice(uid);
    g_state->host_hb_cache.clear();
}

struct DriverSyncBackend {
    soundbridge::ControlSnapshot readControl() const {
        return soundbridge::readControl("/tmp/soundbridge-devices.txt");
    }
    soundbridge::LockStatus hostLock(const soundbridge::ControlSnapshot& session) const {
        return HostLockStatus(session.ownerUID, session.session);
    }
    HeartbeatStatus heartbeat(const std::string& uid, const soundbridge::ControlSnapshot& session) const {
        return HostHeartbeatStatus(uid, session);
    }
    void clearSession() const {
        RemoveAllSessionDevices();
        g_state->device_removal_times.clear();
    }
    std::vector<std::string> deviceUIDs() const {
        std::vector<std::string> result;
        for (const auto& entry : g_state->devices) result.push_back(entry.first);
        return result;
    }
    bool hasDevice(const std::string& uid) const { return g_state->devices.count(uid) != 0; }
    bool inCooldown(const std::string& uid) const { return IsDeviceInCooldown(uid); }
    void removeDevice(const std::string& uid) const { RemoveDevice(uid); }
    void addDevice(const std::string& name, const std::string& uid,
                   const soundbridge::ControlSnapshot& session) const {
        AddDevice(name, uid, session);
        g_state->device_removal_times.erase(uid);
    }
};

void SyncDevices() {
    if (!g_state) return;
    // Darwin notify 与轮询共用同一状态及 libASPL 设备集合。
    std::lock_guard<std::mutex> guard(g_state->sync_mutex);
    DriverSyncBackend backend;
    const auto result = soundbridge::synchronizeDevices(g_state->session, backend);
    if (result.controlStatus != soundbridge::ControlStatus::valid) {
        RF_LOG_INFO("SyncDevices: control read rejected (status=%d); checking the accepted session's heartbeat",
                    static_cast<int>(result.controlStatus));
    } else if (result.decision != soundbridge::SessionDecision::adopted &&
               result.decision != soundbridge::SessionDecision::refreshed) {
        RF_LOG_INFO("SyncDevices: session rejected (decision=%d)", static_cast<int>(result.decision));
    }
}

void MonitorControlFile() {
    // Register Darwin notification listener for immediate device sync
    int notify_token = 0;
    int reg_status = notify_register_dispatch(
        "com.soundbridge.devices-changed",
        &notify_token,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int token) {
            if (g_state && !g_state->should_stop) {
                RF_LOG_INFO("Darwin notification received, syncing devices");
                SyncDevices();
            }
        }
    );

    if (reg_status != NOTIFY_STATUS_OK) {
        RF_LOG_ERROR("Failed to register Darwin notification (status: %d), using polling only", reg_status);
    }

    // Keep existing polling loop as fallback
    while (!g_state->should_stop) {
        SyncDevices();
        for (int i = 0; i < 10 && !g_state->should_stop; i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    // Cleanup
    if (reg_status == NOTIFY_STATUS_OK) {
        notify_cancel(notify_token);
    }
}

std::shared_ptr<aspl::Driver> CreateSoundBridgeDriver() {


    g_state = new SoundBridgeGlobalState();
    g_state->context = std::make_shared<aspl::Context>();
    g_state->plugin = std::make_shared<aspl::Plugin>(g_state->context);

    SyncDevices();

    g_state->driver = std::make_shared<aspl::Driver>(g_state->context, g_state->plugin);

    RF_LOG_INFO("✓ Driver ready - %zu devices", g_state->devices.size());
    RF_LOG_INFO("Features: Multi-rate, Multi-format, SRC, Auto-recovery");
    g_state->monitor_thread = std::thread(MonitorControlFile);

    return g_state->driver;
}

} // namespace

extern "C" void* SoundBridgeDriverPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    static std::shared_ptr<aspl::Driver> driver = CreateSoundBridgeDriver();
    return driver->GetReference();
}
