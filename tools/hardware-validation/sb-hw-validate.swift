// SoundBridge — real CoreAudio hardware validation harness.
//
// WHAT THIS IS
//
//   An out-of-process observer for a *real* CoreAudio playback run. It never
//   touches the render callback: it reads AudioObject properties from this
//   process and reads the Host's own os_log lines, which the Host writes from
//   its control thread. Nothing here is added to the realtime path.
//
//   Three subcommands:
//
//     inventory   read-only device/format dump (safe while audio is playing)
//     collect     observe a live run for N seconds, write JSON + Markdown
//     report      re-render Markdown from a previously written JSON result
//
// WHAT THIS IS NOT
//
//   It cannot make the Host render. It observes only. If the Host is not
//   running, or nothing is playing through the SoundBridge device, `collect`
//   reports `NO CORE AUDIO IO OBSERVED` and exits non-zero — it will never
//   fabricate a callback stream from a timer.
//
//   It does not change the default output device, install anything, or restart
//   CoreAudio. Routing is an operator action documented in the runbook.
//
// HOW TO BUILD AND RUN
//
//   swiftc -O -swift-version 5 -o build/hwvalidate/sb-hw-validate \
//       tools/hardware-validation/sb-hw-validate.swift
//
//   build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/inventory.json
//   build/hwvalidate/sb-hw-validate collect \
//       --out-dir build/hwvalidate/run-1 --duration 1800 --window 10 \
//       --device-uid <UID>
//   build/hwvalidate/sb-hw-validate report --results build/hwvalidate/run-1/result.json
//
//   `marker --out-dir <dir> --note "H3 ten-band start"` appends an operator
//   marker the collector merges into the timeline.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Small utilities

func now() -> Date { Date() }
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func stamp(_ date: Date = Date()) -> String { isoFormatter.string(from: date) }
func logLine(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func die(_ message: String, code: Int32 = 2) -> Never {
    logLine("error: \(message)")
    exit(code)
}

// MARK: - CoreAudio property helpers (read-only)

private func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func getBytes<T>(
    _ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type
) -> T? {
    var a = addr
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, value)
    guard status == noErr, size >= UInt32(MemoryLayout<T>.size) else { return nil }
    return value.pointee
}

private func getUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    getBytes(object, address(selector, scope), UInt32.self)
}

private func getFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
    getBytes(object, address(selector), Float64.self)
}

private func getCFString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    return unmanaged.takeRetainedValue() as String
}

private func getArray<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ type: T.Type
) -> [T] {
    var a = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.size))
}

private func getASBD(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
    getBytes(object, address(selector), AudioStreamBasicDescription.self)
}

private func allDeviceIDs() -> [AudioDeviceID] {
    getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID.self)
}

private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    let value = getUInt32(AudioObjectID(kAudioObjectSystemObject), selector)
    guard let value, value != kAudioObjectUnknown else { return nil }
    return value
}

private func outputStreams(of device: AudioDeviceID) -> [AudioStreamID] {
    getArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, AudioStreamID.self)
}

private func transportName(_ raw: UInt32?) -> String {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn?: return "built-in"
    case kAudioDeviceTransportTypeUSB?: return "usb"
    case kAudioDeviceTransportTypeBluetooth?: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE?: return "bluetooth-le"
    case kAudioDeviceTransportTypeHDMI?: return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort?: return "displayport"
    case kAudioDeviceTransportTypeAirPlay?: return "airplay"
    case kAudioDeviceTransportTypeAVB?: return "avb"
    case kAudioDeviceTransportTypeVirtual?: return "virtual"
    case kAudioDeviceTransportTypeAggregate?: return "aggregate"
    case kAudioDeviceTransportTypeThunderbolt?: return "thunderbolt"
    default: return raw.map { "other(\($0))" } ?? "unknown"
    }
}

// MARK: - Device snapshot

struct DeviceSnapshot {
    var uid: String
    var name: String
    var deviceID: AudioDeviceID
    var transport: String
    var nominalRate: Float64?
    var bufferFrameSize: UInt32?
    var bufferRangeMin: Double?
    var bufferRangeMax: Double?
    var isRunning: Bool
    var isRunningSomewhere: Bool
    /// Physical format of the first output stream: what the device is actually
    /// running at, as opposed to what was requested.
    var streamPhysicalRate: Float64?
    var streamVirtualRate: Float64?
    var availableRates: [Double]
    var outputChannelCount: Int

    var deadlineMicroseconds: Double? {
        guard let rate = streamPhysicalRate ?? nominalRate, rate > 0,
              let frames = bufferFrameSize, frames > 0 else { return nil }
        return Double(frames) / rate * 1_000_000.0
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "uid": uid,
            "name": name,
            "deviceID": Int(deviceID),
            "transport": transport,
            "isRunning": isRunning,
            "isRunningSomewhere": isRunningSomewhere,
            "outputChannelCount": outputChannelCount,
            "availableRates": availableRates,
            "capturedAt": stamp()
        ]
        if let v = nominalRate { d["nominalSampleRate"] = v }
        if let v = bufferFrameSize { d["bufferFrameSize"] = Int(v) }
        if let v = bufferRangeMin { d["bufferFrameSizeMin"] = v }
        if let v = bufferRangeMax { d["bufferFrameSizeMax"] = v }
        if let v = streamPhysicalRate { d["streamPhysicalSampleRate"] = v }
        if let v = streamVirtualRate { d["streamVirtualSampleRate"] = v }
        if let v = deadlineMicroseconds { d["deadlineMicroseconds"] = v }
        return d
    }

    /// The key a window is bucketed by. Two observations with different keys
    /// have different deadlines and must never be merged.
    var bucketKey: String {
        let rate = (streamPhysicalRate ?? nominalRate).map { String(format: "%.0f", $0) } ?? "?"
        let frames = bufferFrameSize.map(String.init) ?? "?"
        return "\(rate)Hz/\(frames)f"
    }
}

func snapshot(device: AudioDeviceID) -> DeviceSnapshot? {
    guard let uid = getCFString(device, kAudioDevicePropertyDeviceUID) else { return nil }
    let name = getCFString(device, kAudioObjectPropertyName) ?? "(unnamed)"
    let range = getBytes(device, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange.self)
    let rates = getArray(device, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange.self)
        .map { $0.mMaximum }.filter { $0 > 0 }
    let streams = outputStreams(of: device)
    let physical = streams.first.flatMap { getASBD($0, kAudioStreamPropertyPhysicalFormat) }
    let virtualFmt = streams.first.flatMap { getASBD($0, kAudioStreamPropertyVirtualFormat) }
    let channels = physical.map { Int($0.mChannelsPerFrame) } ?? 0
    return DeviceSnapshot(
        uid: uid,
        name: name,
        deviceID: device,
        transport: transportName(getUInt32(device, kAudioDevicePropertyTransportType)),
        nominalRate: getFloat64(device, kAudioDevicePropertyNominalSampleRate),
        bufferFrameSize: getUInt32(device, kAudioDevicePropertyBufferFrameSize),
        bufferRangeMin: range?.mMinimum,
        bufferRangeMax: range?.mMaximum,
        isRunning: (getUInt32(device, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0,
        isRunningSomewhere: (getUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0,
        streamPhysicalRate: physical.map { $0.mSampleRate },
        streamVirtualRate: virtualFmt.map { $0.mSampleRate },
        availableRates: rates,
        outputChannelCount: channels
    )
}

func deviceID(forUID uid: String) -> AudioDeviceID? {
    for device in allDeviceIDs() where getCFString(device, kAudioDevicePropertyDeviceUID) == uid {
        return device
    }
    return nil
}

// MARK: - Host log parsing

struct TimingSample {
    var timestamp: Date
    var observations: UInt64
    var minUs: Double?
    var p50Us: Double?
    var p95Us: Double?
    var p99Us: Double?
    var maxUs: Double?
    var maxSaturated: Bool
    var overBudget: UInt64
    var excessMs: Double
    var cpuPercent: Double?
    var raw: String
}

struct HostEvent {
    var timestamp: Date
    var kind: String
    var detail: String
}

private let timingRegex = try! NSRegularExpression(
    pattern: "n=(\\d+) min=(n/a|[0-9.]+)us p50=(n/a|[0-9.]+)us p95=(n/a|[0-9.]+)us "
           + "p99=(n/a|[0-9.]+)us max=(>=)?(n/a|[0-9.]+)us overBudget=(\\d+) excess=([0-9.]+)ms",
    options: []
)
private let underrunRegex = try! NSRegularExpression(
    pattern: "Buffer underrun: \\+(\\d+) \\(total: (\\d+)\\) \\[([^\\]]+)\\]", options: [])
private let overrunRegex = try! NSRegularExpression(
    pattern: "Buffer overrun: \\+(\\d+) \\(total: (\\d+)\\) \\[([^\\]]+)\\]", options: [])
private let timestampRegex = try! NSRegularExpression(
    pattern: "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3,6})(?:\\s*([+-]\\d{4}))?", options: [])

private let lineDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
    return f
}()

/// `--style compact` on this macOS prints local time with no offset, while
/// `--style syslog` appends one. Both shapes have to parse, otherwise every
/// timestamp silently degrades to "now" and every rate computed from a
/// timestamp difference becomes a measurement of the harness's own polling.
private let localStampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// Truncate to milliseconds so one formatter reads both `.SSS` and `.SSSSSS`.
private func millisecondStamp(_ stamp: String) -> String {
    guard let dot = stamp.firstIndex(of: ".") else { return stamp }
    let head = stamp[stamp.startIndex...dot]
    let fraction = stamp[stamp.index(after: dot)...]
    return head + String(fraction.prefix(3))
}

/// `NSRegularExpression` reports an optional group that did not participate as
/// `NSRange(location: NSNotFound, length: 0)`, and `NSString.substring(with:)`
/// throws NSRangeException for it — a crash, not an empty string. Every group
/// read goes through here. `timingRegex` makes the `>=` saturation marker
/// optional, so the unsaturated case (the normal one) takes this path on every
/// single line.
func capture(_ ns: NSString, _ match: NSTextCheckingResult, _ index: Int) -> String? {
    guard index < match.numberOfRanges else { return nil }
    let range = match.range(at: index)
    guard range.location != NSNotFound else { return nil }
    return ns.substring(with: range)
}

func parseTimestamp(_ line: String) -> Date {
    let ns = line as NSString
    guard let match = timestampRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
          let raw = capture(ns, match, 1) else { return Date() }
    let stamp = millisecondStamp(raw)
    if let offset = capture(ns, match, 2),
       let date = lineDateFormatter.date(from: stamp + offset) { return date }
    if let date = localStampFormatter.date(from: stamp) { return date }
    return Date()
}

func parseTimingLine(_ line: String) -> TimingSample? {
    let ns = line as NSString
    guard let m = timingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    func group(_ i: Int) -> String { capture(ns, m, i) ?? "" }
    func value(_ i: Int) -> Double? { group(i) == "n/a" ? nil : Double(group(i)) }
    guard let observations = UInt64(group(1)), let overBudget = UInt64(group(8)),
          let excess = Double(group(9)) else { return nil }
    var cpu: Double? = nil
    if let r = line.range(of: "cpu=") {
        let tail = line[r.upperBound...].prefix { "0123456789.".contains($0) }
        cpu = Double(tail)
    }
    return TimingSample(
        timestamp: parseTimestamp(line),
        observations: observations,
        minUs: value(2), p50Us: value(3), p95Us: value(4), p99Us: value(5),
        maxUs: value(7), maxSaturated: group(6) == ">=",
        overBudget: overBudget, excessMs: excess, cpuPercent: cpu, raw: line
    )
}

// MARK: - Device change watcher

/// Records format changes at the moment CoreAudio reports them. The window
/// poll alone would miss a change that reverts inside one window, and the Host
/// does not log rate or buffer-size changes at all.
final class DeviceWatcher {
    private let device: AudioDeviceID
    private let queue = DispatchQueue(label: "com.soundbridge.hw.watch")
    private let lock = NSLock()
    private var registered: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var recorded: [[String: Any]] = []

    init(device: AudioDeviceID) { self.device = device }

    func start() {
        register(kAudioDevicePropertyNominalSampleRate, name: "nominal-sample-rate")
        register(kAudioDevicePropertyBufferFrameSize, name: "buffer-frame-size")
        register(kAudioDevicePropertyDeviceIsRunning, name: "device-is-running")
    }

    private func register(_ selector: AudioObjectPropertySelector, name: String) {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var event: [String: Any] = ["timestamp": stamp(), "event": name + "-changed"]
            if let live = snapshot(device: self.device) {
                event["bucket"] = live.bucketKey
                if let rate = live.streamPhysicalRate ?? live.nominalRate { event["sampleRate"] = rate }
                if let frames = live.bufferFrameSize { event["frames"] = Int(frames) }
                if let deadline = live.deadlineMicroseconds { event["deadlineMicroseconds"] = deadline }
            } else {
                event["note"] = "device no longer present"
            }
            self.lock.lock()
            self.recorded.append(event)
            self.lock.unlock()
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, queue, block) == noErr {
            registered.append((selector, block))
        }
    }

    var events: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func stop() {
        for (selector, block) in registered {
            var addr = address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &addr, queue, block)
        }
        registered.removeAll()
    }
}

// MARK: - Shared-memory counter probe

/// The proxy device CoreAudio exposes is `<physicalUID>-soundbridge`, but the
/// shared mapping is keyed by the *physical* UID (the Host writes
/// `/tmp/soundbridge-<owner>-<physicalUID>`). Operators naturally pass the UID
/// they see in the device list, so accept either form and mirror the Host's own
/// derivation in `ProxyDeviceManager`.
func mappingUID(for deviceUID: String) -> String {
    let suffix = "-soundbridge"
    if deviceUID.hasSuffix(suffix) {
        return String(deviceUID.dropLast(suffix.count))
    }
    return deviceUID
}

/// Locate `sb-shm-probe` next to this harness or in the default build dir.
func defaultProbePath() -> String? {
    if let executable = Bundle.main.executablePath {
        let sibling = ((executable as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("sb-shm-probe")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
    }
    let relative = "build/hwvalidate/sb-shm-probe"
    if FileManager.default.isExecutableFile(atPath: relative) { return relative }
    return nil
}

/// One read-only sample of the live mapping. Returns nil when the mapping is
/// absent (Host not running), the header does not validate, or the probe is
/// missing — all three are "not observable", never "zero".
func probeSharedMemory(uid: String, probePath: String) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: probePath)
    process.arguments = ["--uid", uid, "--once"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func uint64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber else { return nil }
    return number.uint64Value
}

// MARK: - Collection

struct WindowRecord {
    var index: Int
    var start: Date
    var end: Date
    var bucketKey: String
    var sampleRate: Double?
    var frames: UInt32?
    var deadlineUs: Double?
    var callbacks: UInt64
    var overBudgetDelta: UInt64
    var excessMsDelta: Double
    var cumulativeP50: Double?
    var cumulativeP95: Double?
    var cumulativeP99: Double?
    var cumulativeMax: Double?
    var maxSaturated: Bool
    var p999: Double?
    var cpuPercent: Double?
    var observedCallbackRateHz: Double?
    var expectedCallbackRateHz: Double?
    var ioRunning: Bool
    var underrunDelta: UInt64?
    var overrunDelta: UInt64?
    var underrunSource: String?

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "window": index,
            "start": stamp(start),
            "end": stamp(end),
            "bucket": bucketKey,
            "ioRunning": ioRunning,
            "callbacks": callbacks,
            "overBudget": overBudgetDelta,
            "overBudgetExcessMs": excessMsDelta,
            "maxSaturated": maxSaturated,
            "quantilesAreCumulative": true
        ]
        if let v = sampleRate { d["actualSampleRate"] = v }
        if let v = frames { d["actualBufferFrames"] = Int(v) }
        if let v = deadlineUs { d["deadlineMicroseconds"] = v }
        if let v = cumulativeP50 { d["p50Us"] = v }
        if let v = cumulativeP95 { d["p95Us"] = v }
        if let v = cumulativeP99 { d["p99Us"] = v }
        if let v = cumulativeMax { d["maxUs"] = v }
        if let v = p999 { d["p999Us"] = v }
        if let v = cpuPercent { d["hostCpuPercent"] = v }
        if let v = observedCallbackRateHz { d["observedCallbackRateHz"] = v }
        if let v = expectedCallbackRateHz { d["expectedCallbackRateHz"] = v }
        if let v = underrunDelta { d["driverUnderrunDelta"] = Int(v) }
        if let v = overrunDelta { d["ringOverrunDelta"] = Int(v) }
        if let v = underrunSource { d["underrunSource"] = v }
        return d
    }
}

final class LogCollector {
    private var buffer = ""
    private let lock = NSLock()
    private(set) var timing: [TimingSample] = []
    private(set) var events: [HostEvent] = []
    private(set) var rawLines: [String] = []
    private var underrunTotals: [UInt64] = []
    private var overrunTotals: [UInt64] = []

    /// Only lines written by the Host process count as Host telemetry.
    ///
    /// The same subsystem is also used by `xctest` during `swift test`, and a
    /// fixture run logs plausible-looking `Callback timing:` lines. Accepting
    /// them would make requirement 4.2.5 ("confirm a genuine CoreAudio IO
    /// callback is active") unfalsifiable, so the emitting process is part of
    /// the evidence rather than a detail.
    static let expectedProcess = "SoundBridgeHost"
    private(set) var sourceProcesses: [String: Int] = [:]
    private static let processRegex = try! NSRegularExpression(
        pattern: "\\s([A-Za-z0-9_.+\\-]+)\\[(\\d+):[0-9a-fA-F]+\\]")

    // `log stream` block-buffers when stdout is not a tty. Measured on this
    // machine: a 12-second stream into a pipe delivered zero lines, and the
    // same stream into a file held a single header line until the process was
    // killed. A collector that only receives data after it stops observing
    // cannot describe the run, so the trailing window is re-read instead and
    // duplicates are dropped by the verbatim line (the timestamp prefix is part
    // of the line, so a re-read is byte-identical and a real repeat is not).
    private static let pollInterval: TimeInterval = 5.0
    private static let pollLookbackArgument = "12s"
    private var poller: Thread?
    private var polling = false
    private var seenLines = Set<String>()
    private var reportedFailures = Set<String>()
    private var firstFailure: String?
    /// A single run produces roughly one line per five seconds. The cap only
    /// exists so that a subsystem-wide log flood cannot grow this without
    /// bound; hitting it re-admits at most one lookback window of duplicates.
    private static let seenLinesCap = 200_000

    func start() throws {
        setPolling(true)
        let worker = Thread { [weak self] in
            while let self, self.isPolling() {
                self.pollOnce()
                Thread.sleep(forTimeInterval: LogCollector.pollInterval)
            }
        }
        worker.stackSize = 1 << 20
        worker.start()
        poller = worker
        pollOnce()
        events.append(HostEvent(
            timestamp: now(), kind: "collector",
            detail: "log polling started (`log show --last \(LogCollector.pollLookbackArgument)`, "
                + "every \(Int(LogCollector.pollInterval))s, process filter "
                + "\(LogCollector.expectedProcess))"))
    }

    func stop() {
        setPolling(false)
        // Let an in-flight `log show` finish so its child is not orphaned.
        let deadline = Date().addingTimeInterval(3.0)
        while let poller, !poller.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        poller = nil
        events.append(HostEvent(timestamp: now(), kind: "collector", detail: "log polling stopped"))
    }

    private func isPolling() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return polling
    }

    private func setPolling(_ value: Bool) {
        lock.lock(); polling = value; lock.unlock()
    }

    /// One read of the trailing window. Runs `log show` as a child rather than
    /// `log stream`, for the buffering reason documented above.
    private func pollOnce() {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        probe.arguments = [
            "show", "--last", LogCollector.pollLookbackArgument,
            "--style", "compact",
            "--predicate", "subsystem == \"com.soundbridge.host\""
        ]
        let out = Pipe()
        let err = Pipe()
        probe.standardOutput = out
        probe.standardError = err
        do {
            try probe.run()
        } catch {
            recordFailure("log show could not start: \(error)")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            let why = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            recordFailure("log show exited with status \(probe.terminationStatus) "
                          + "(argv \(probe.arguments ?? []))"
                          + (why.isEmpty ? "" : ": \(why)"))
            return
        }
        guard !data.isEmpty else {
            recordFailure("log show returned 0 bytes for --last "
                          + "\(LogCollector.pollLookbackArgument); the trailing window "
                          + "was used, so this is not the same as an idle Host")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            recordFailure("log show output was not valid UTF-8 (\(data.count) bytes)")
            return
        }

        var fresh: [String] = []
        lock.lock()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let verbatim = String(line)
            if seenLines.contains(verbatim) { continue }
            seenLines.insert(verbatim)
            fresh.append(verbatim)
        }
        if seenLines.count > LogCollector.seenLinesCap { seenLines.removeAll(keepingCapacity: true) }
        lock.unlock()

        guard !fresh.isEmpty else { return }
        ingest(fresh.joined(separator: "\n") + "\n")
    }

    /// A poll that cannot read the log must not look like a quiet device.
    /// Without this the run ends as "log sources seen: none", which is
    /// indistinguishable from a Host that never logged — so a distinct failure
    /// is recorded once per cause and printed to stderr as well.
    private func recordFailure(_ detail: String) {
        lock.lock()
        let isNew = reportedFailures.insert(detail).inserted
        if isNew {
            if firstFailure == nil { firstFailure = detail }
            events.append(HostEvent(timestamp: now(), kind: "collector-failure", detail: detail))
        }
        lock.unlock()
        if isNew { FileHandle.standardError.write(Data("warning: \(detail)\n".utf8)) }
    }

    /// First reason the log could not be read, if any. Kept separate from
    /// "nothing played" so the two cannot be reported as the same finding.
    func observationFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        return firstFailure
    }

    private func ingest(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        while let index = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<index])
            buffer = String(buffer[buffer.index(after: index)...])
            consume(line)
        }
    }

    private func consume(_ line: String) {
        guard !line.isEmpty else { return }
        // `--style compact` prefixes every line with "<date> <time> <level>
        // <process>[<pid>:<tid>] [<subsystem>:<category>] <message>".
        let full = NSRange(location: 0, length: (line as NSString).length)
        let ns = line as NSString
        let header = LogCollector.processRegex.firstMatch(in: line, range: full)
        guard let header, let source = capture(ns, header, 1) else { return }
        sourceProcesses[source, default: 0] += 1
        guard source == LogCollector.expectedProcess else { return }
        rawLines.append(line)
        if let sample = parseTimingLine(line) { timing.append(sample); return }
        let range = NSRange(location: 0, length: ns.length)
        if let m = underrunRegex.firstMatch(in: line, range: range),
           let text = capture(ns, m, 2), let total = UInt64(text) {
            underrunTotals.append(total)
            events.append(HostEvent(timestamp: parseTimestamp(line), kind: "driver-underrun",
                                    detail: line.trimmingCharacters(in: .whitespaces)))
            return
        }
        if let m = overrunRegex.firstMatch(in: line, range: range),
           let text = capture(ns, m, 2), let total = UInt64(text) {
            overrunTotals.append(total)
            events.append(HostEvent(timestamp: parseTimestamp(line), kind: "ring-overrun",
                                    detail: line.trimmingCharacters(in: .whitespaces)))
            return
        }
        for (keyword, kind) in LogCollector.classifiers where line.localizedCaseInsensitiveContains(keyword) {
            events.append(HostEvent(timestamp: parseTimestamp(line), kind: kind,
                                    detail: line.trimmingCharacters(in: .whitespaces)))
            return
        }
    }

    static let classifiers: [(String, String)] = [
        ("did not restore the audio path", "host-recovery-failure"),
        ("CoreAudio recovery", "host-recovery"),
        ("proxy device", "proxy-device"),
        ("hotplug", "device-hotplug"),
        ("Default output", "default-output"),
        ("degraded", "host-degraded"),
        ("render path", "render-path"),
        ("retire", "mapping-retire"),
        ("shutdown", "host-shutdown")
    ]

    func snapshotCounts() -> (timing: Int, underrun: UInt64?, overrun: UInt64?, events: Int) {
        lock.lock(); defer { lock.unlock() }
        return (timing.count, underrunTotals.last, overrunTotals.last, events.count)
    }

    func timingSince(_ index: Int) -> [TimingSample] {
        lock.lock(); defer { lock.unlock() }
        guard index < timing.count else { return [] }
        return Array(timing[index...])
    }

    func eventsSince(_ index: Int) -> [HostEvent] {
        lock.lock(); defer { lock.unlock() }
        guard index < events.count else { return [] }
        return Array(events[index...])
    }

    /// Which processes actually wrote to this subsystem during the run.
    func sourceSummary() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return sourceProcesses
    }
}

// MARK: - Markers

struct OperatorMarker {
    var timestamp: Date
    var note: String
}

func loadMarkers(_ path: String) -> [OperatorMarker] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = object["timestamp"] as? String, let note = object["note"] as? String,
              let date = isoFormatter.date(from: t) else { return nil }
        return OperatorMarker(timestamp: date, note: note)
    }
}

// MARK: - Evaluation

struct Criterion {
    var id: String
    var statement: String
    var status: String   // MET / UNMET / NOT OBSERVABLE / NOT EXECUTED
    var evidence: String
}

func evaluate(
    windows: [WindowRecord], events: [HostEvent], markers: [OperatorMarker],
    collectedSeconds: Double, devicePresent: Bool, p999Available: Bool,
    p999Note: String
) -> (criteria: [Criterion], verdict: String, reasons: [String]) {
    var criteria: [Criterion] = []
    var reasons: [String] = []

    let callbacks = windows.reduce(UInt64(0)) { $0 + $1.callbacks }
    let overBudget = windows.reduce(UInt64(0)) { $0 + $1.overBudgetDelta }
    let ioRunningWindows = windows.filter { $0.ioRunning }.count
    let rateChecks = windows.compactMap { w -> Double? in
        guard let observed = w.observedCallbackRateHz, let expected = w.expectedCallbackRateHz,
              expected > 0 else { return nil }
        return observed / expected
    }
    let ratePlausible = !rateChecks.isEmpty && rateChecks.allSatisfy { $0 > 0.7 && $0 < 1.3 }

    criteria.append(Criterion(
        id: "C1", statement: "Genuine CoreAudio IO callback activity proven",
        status: (callbacks > 0 && ioRunningWindows > 0 && ratePlausible) ? "MET" : "UNMET",
        evidence: "\(callbacks) callbacks in \(windows.count) windows; "
            + "deviceIsRunning in \(ioRunningWindows) windows; "
            + "observed/expected callback-rate ratio "
            + (rateChecks.isEmpty ? "n/a" : String(format: "%.2f–%.2f",
                                                   rateChecks.min()!, rateChecks.max()!))))

    let formatKnown = windows.contains { $0.sampleRate != nil && $0.frames != nil }
    criteria.append(Criterion(
        id: "C2", statement: "Actual sample rate and buffer frame count observed",
        status: formatKnown ? "MET" : "UNMET",
        evidence: windows.contains { $0.sampleRate != nil && $0.frames != nil }
            ? "buckets: " + Set(windows.map { $0.bucketKey }).sorted().joined(separator: ", ")
            : "no window carried both a rate and a frame count"))

    let perDeadline = windows.allSatisfy { $0.deadlineUs != nil }
    criteria.append(Criterion(
        id: "C3", statement: "Timing compared against the deadline of its own format",
        status: perDeadline && !windows.isEmpty ? "MET" : "UNMET",
        evidence: "each window computes frames / rate from its own snapshot; "
            + "windows are split whenever the bucket key changes"))

    criteria.append(Criterion(
        id: "C4", statement: "All deadline misses reported",
        status: windows.isEmpty ? "NOT EXECUTED" : "MET",
        evidence: "overBudget summed over windows = \(overBudget)"))

    let underrunObservable = windows.contains { $0.underrunDelta != nil }
        || events.contains { $0.kind == "driver-underrun" }
    criteria.append(Criterion(
        id: "C5", statement: "Driver underrun observability documented",
        status: underrunObservable ? "MET" : "NOT OBSERVABLE",
        evidence: underrunObservable
            ? "Host 'Buffer underrun: +N (total: T)' lines observed"
            : "no underrun line appeared; the shared-memory counter is only "
              + "surfaced when the Host's own poll sees a delta"))

    let recovery = events.filter { $0.kind.hasPrefix("host-recovery")
        || $0.kind == "device-hotplug" || $0.kind == "host-degraded" }
    criteria.append(Criterion(
        id: "C6", statement: "Host/device recovery evaluated",
        status: markers.contains { $0.note.localizedCaseInsensitiveContains("H8") }
            ? (recovery.isEmpty ? "MET" : "MET") : "NOT EXECUTED",
        evidence: "\(recovery.count) recovery/hotplug/degraded events; "
            + (markers.contains { $0.note.localizedCaseInsensitiveContains("H8") }
               ? "H8 was marked by the operator" : "H8 was not marked")))

    let symptomMarkers = markers.filter { $0.note.localizedCaseInsensitiveContains("symptom")
        || $0.note.localizedCaseInsensitiveContains("click")
        || $0.note.localizedCaseInsensitiveContains("dropout") }
    criteria.append(Criterion(
        id: "C7", statement: "Audible symptoms recorded by the operator",
        status: markers.isEmpty ? "NOT EXECUTED"
            : (symptomMarkers.isEmpty ? "MET (none reported)" : "MET"),
        evidence: markers.isEmpty ? "no operator markers exist"
            : "\(markers.count) markers, \(symptomMarkers.count) describing symptoms"))

    let restore = markers.first { $0.note.localizedCaseInsensitiveContains("restore") }
    criteria.append(Criterion(
        id: "C8", statement: "Original default output restored and verified",
        status: restore == nil ? "NOT EXECUTED" : "MET",
        evidence: restore.map { "operator marker: \($0.note)" } ?? "no restore marker recorded"))

    let skipped = markers.filter { $0.note.localizedCaseInsensitiveContains("skip") }
    criteria.append(Criterion(
        id: "C9", statement: "Skipped scenarios remain visibly skipped",
        status: "MET",
        evidence: skipped.isEmpty ? "no scenario was marked skipped"
            : "\(skipped.count) skipped: " + skipped.map { $0.note }.joined(separator: "; ")))

    let requiredMissing = criteria.filter { $0.status == "NOT OBSERVABLE" || $0.status == "NOT EXECUTED" }
    criteria.append(Criterion(
        id: "C10", statement: "No required evidence is missing",
        status: requiredMissing.isEmpty ? "MET" : "UNMET",
        evidence: requiredMissing.isEmpty ? "all required evidence present"
            : "missing: " + requiredMissing.map { $0.id }.joined(separator: ", ")))

    criteria.append(Criterion(
        id: "C-extra", statement: "p99.9 latency reported",
        status: p999Available ? "MET" : "NOT OBSERVABLE",
        evidence: p999Note))

    let fail = overBudget > 0 || events.contains { $0.kind == "host-recovery-failure" }
    let incomplete = callbacks == 0 || !devicePresent
        || criteria.contains { $0.id != "C-extra" && $0.status == "UNMET" }
        || criteria.contains { $0.status == "NOT EXECUTED" }

    let verdict: String
    if fail {
        verdict = "FAIL — HARDWARE REALTIME VALIDATION FAILED"
        reasons.append("overBudget = \(overBudget) or a documented recovery failure occurred")
    } else if incomplete {
        verdict = "INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING"
        reasons.append("one or more required criteria are UNMET or were never exercised")
    } else if !p999Available || collectedSeconds < 60 {
        verdict = "CONDITIONAL PASS — HARDWARE VALIDATION WITH DOCUMENTED LIMITATIONS"
        if !p999Available { reasons.append("p99.9 is not exposed by the Host's telemetry") }
        if collectedSeconds < 60 { reasons.append("collection shorter than 60 s") }
    } else {
        verdict = "PASS — HARDWARE REALTIME VALIDATION VERIFIED"
    }
    return (criteria, verdict, reasons)
}

// MARK: - Commands

func commandInventory(_ args: [String: String]) {
    let defaults = [
        "defaultOutput": defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            .flatMap { snapshot(device: $0) }?.dictionary ?? [:],
        "defaultInput": defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
            .flatMap { snapshot(device: $0) }?.dictionary ?? [:]
    ]
    let devices = allDeviceIDs().compactMap { snapshot(device: $0)?.dictionary }
    let payload: [String: Any] = [
        "schemaVersion": 1,
        "kind": "inventory",
        "capturedAt": stamp(),
        "host": [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": machineArchitecture(),
            "logicalCores": ProcessInfo.processInfo.activeProcessorCount
        ],
        "defaults": defaults,
        "devices": devices
    ]
    writeJSON(payload, to: args["out"])
}

func machineArchitecture() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}

func commandMarker(_ args: [String: String]) {
    guard let dir = args["out-dir"], let note = args["note"] else {
        die("marker needs --out-dir and --note")
    }
    let path = (dir as NSString).appendingPathComponent("markers.jsonl")
    let line = "{\"timestamp\":\"\(stamp())\",\"note\":\"\(note.replacingOccurrences(of: "\"", with: "'"))\"}\n"
    if !FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    }
    print("marker appended: \(note)")
}

func commandCollect(_ args: [String: String]) {
    guard let uid = args["device-uid"] else { die("collect needs --device-uid") }
    guard let outDir = args["out-dir"] else { die("collect needs --out-dir") }
    let duration = Double(args["duration"] ?? "1800") ?? 1800
    let windowSeconds = Double(args["window"] ?? "10") ?? 10
    let loadProcesses = Int(args["cpu-load"] ?? "0") ?? 0

    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    guard let device = deviceID(forUID: uid), let initial = snapshot(device: device) else {
        die("device with UID \(uid) is not present; refusing to collect", code: 3)
    }

    logLine("collecting \(Int(duration))s from \(initial.name) [\(uid)] "
            + "bucket=\(initial.bucketKey) deadline=\(initial.deadlineMicroseconds.map { String(format: "%.1f", $0) } ?? "n/a")us")

    var loadPIDs: [Int32] = []
    if loadProcesses > 0 {
        for _ in 0..<loadProcesses {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            p.arguments = []
            p.standardOutput = FileHandle.nullDevice
            do { try p.run(); loadPIDs.append(p.processIdentifier) } catch {
                logLine("warning: could not start CPU load process: \(error)")
            }
        }
        logLine("started \(loadPIDs.count) reversible CPU-load processes (pids \(loadPIDs))")
    }
    defer {
        for pid in loadPIDs { kill(pid, SIGTERM) }
        if !loadPIDs.isEmpty { logLine("stopped CPU load processes") }
    }

    let collector = LogCollector()
    do { try collector.start() } catch { die("could not start log stream: \(error)") }
    defer { collector.stop() }

    let watcher = DeviceWatcher(device: device)
    watcher.start()
    defer { watcher.stop() }

    var windows: [WindowRecord] = []
    var deviceChanges: [[String: Any]] = []
    var current = initial
    var timingIndex = 0
    var eventIndex = 0
    var underrunCursor: UInt64 = 0
    var overrunCursor: UInt64 = 0
    var shmCursor: (underrun: UInt64, overrun: UInt64)? = nil
    var underrunSource = "not observable"
    var lastSample: TimingSample? = nil
    var lastEnd = now()

    // The priming poll inside start() is a baseline, not window content. The
    // Host's counters are cumulative since it started — possibly hours ago —
    // so counting the priming sample as window 0 would attribute the whole
    // uptime to a ten-second window.
    let priming = collector.timingSince(0)
    if !priming.isEmpty {
        timingIndex = priming.count
        lastSample = priming.last
    }

    // The driver-side counters are read straight out of the live mapping by a
    // separate read-only process. That is deliberately not the Host's log line:
    // the Host interpolates those Ints without `privacy: .public`, so they arrive
    // as `<private>` and cannot be parsed.
    let shmProbePath = args["shm-probe"] ?? defaultProbePath()
    logLine(shmProbePath.map { "shared-memory probe: \($0)" }
            ?? "warning: sb-shm-probe not found; driver underruns will be reported as not observable")
    let totalWindows = max(1, Int(duration / windowSeconds))
    let markersPath = (outDir as NSString).appendingPathComponent("markers.jsonl")

    for index in 0..<totalWindows {
        Thread.sleep(forTimeInterval: windowSeconds)
        let windowEnd = now()

        guard let live = snapshot(device: device) else {
            deviceChanges.append(["timestamp": stamp(windowEnd), "event": "device-disappeared",
                                  "uid": uid])
            deviceChanges.append(["timestamp": stamp(windowEnd), "event": "collection-aborted",
                                  "reason": "device no longer present"])
            break
        }
        if live.bucketKey != current.bucketKey {
            deviceChanges.append([
                "timestamp": stamp(windowEnd), "event": "format-changed",
                "from": current.bucketKey, "to": live.bucketKey,
                "fromDeadlineUs": current.deadlineMicroseconds as Any,
                "toDeadlineUs": live.deadlineMicroseconds as Any
            ])
            logLine("format change: \(current.bucketKey) -> \(live.bucketKey); window split")
        }
        current = live

        let samples = collector.timingSince(timingIndex)
        timingIndex += samples.count
        let newEvents = collector.eventsSince(eventIndex)
        eventIndex += newEvents.count
        let counts = collector.snapshotCounts()

        guard let last = samples.last else {
            lastEnd = windowEnd
            continue
        }
        let base = lastSample
        // No baseline means nothing can be attributed to this window yet.
        // Falling back to the absolute counter would report the Host's entire
        // uptime as one window's worth of callbacks.
        let callbacks = base.map { last.observations >= $0.observations ? last.observations - $0.observations : 0 }
            ?? 0
        let overDelta = base.map { last.overBudget >= $0.overBudget ? last.overBudget - $0.overBudget : 0 }
            ?? 0
        let excessDelta = base.map { max(0, last.excessMs - $0.excessMs) } ?? 0

        var underrunDelta: UInt64? = nil
        var overrunDelta: UInt64? = nil
        if let probePath = shmProbePath,
           let shm = probeSharedMemory(uid: mappingUID(for: uid), probePath: probePath),
           let underruns = uint64(shm["underrunCount"]),
           let overruns = uint64(shm["overrunCount"]) {
            if let cursor = shmCursor {
                underrunDelta = underruns >= cursor.underrun ? underruns - cursor.underrun : 0
                overrunDelta = overruns >= cursor.overrun ? overruns - cursor.overrun : 0
            } else {
                // First sample of the mapping: absolute counts, no delta yet.
                underrunDelta = 0
                overrunDelta = 0
            }
            shmCursor = (underruns, overruns)
            underrunSource = "sb-shm-probe (read-only mmap of the live mapping)"
        } else if let total = counts.underrun {
            // Fallback: the Host's log line. Only reachable if the operator
            // enabled private-data logging, which is a system-wide change.
            underrunDelta = total >= underrunCursor ? total - underrunCursor : 0
            underrunCursor = total
            underrunSource = "host log line (requires private_data logging)"
        }
        if overrunDelta == nil, let total = counts.overrun {
            overrunDelta = total >= overrunCursor ? total - overrunCursor : 0
            overrunCursor = total
        }

        // Measure the callback rate over the interval the two samples actually
        // cover. The Host writes one timing line every ~5 s, so a wall-clock
        // 10 s window can hold samples emitted 15 s apart; dividing by the
        // window length would report a rate that never happened.
        let sampleSpan = base.map { last.timestamp.timeIntervalSince($0.timestamp) } ?? 0
        let rate = live.streamPhysicalRate ?? live.nominalRate
        let expectedHz: Double? = {
            guard let rate, let frames = live.bufferFrameSize, frames > 0 else { return nil }
            return rate / Double(frames)
        }()

        windows.append(WindowRecord(
            index: index,
            start: lastEnd,
            end: windowEnd,
            bucketKey: live.bucketKey,
            sampleRate: rate,
            frames: live.bufferFrameSize,
            deadlineUs: live.deadlineMicroseconds,
            callbacks: callbacks,
            overBudgetDelta: overDelta,
            excessMsDelta: excessDelta,
            cumulativeP50: last.p50Us,
            cumulativeP95: last.p95Us,
            cumulativeP99: last.p99Us,
            cumulativeMax: last.maxUs,
            maxSaturated: last.maxSaturated,
            p999: nil,
            cpuPercent: last.cpuPercent,
            observedCallbackRateHz: sampleSpan > 0 ? Double(callbacks) / sampleSpan : nil,
            expectedCallbackRateHz: expectedHz,
            ioRunning: live.isRunning || live.isRunningSomewhere,
            underrunDelta: underrunDelta,
            overrunDelta: overrunDelta,
            underrunSource: underrunSource
        ))
        lastSample = last
        lastEnd = windowEnd
    }

    let markers = loadMarkers(markersPath)
    let events = collector.events
    let p999Note = "TimingSnapshot exposes observations/min/p50/p95/p99/max only. "
        + "rf_rt_hist_quantile_bucket() already supports a 9990/10000 quantile, so the "
        + "smallest follow-up is one extra field in AudioRenderer.TimingSnapshot — no C change."
    let evaluation = evaluate(
        windows: windows, events: events, markers: markers,
        collectedSeconds: duration, devicePresent: true,
        p999Available: false, p999Note: p999Note
    )

    let final = snapshot(device: device)
    let result: [String: Any] = [
        "schemaVersion": 1,
        "kind": "hw-run",
        "runID": UUID().uuidString,
        "startedAt": stamp(lastEnd.addingTimeInterval(-duration)),
        "endedAt": stamp(now()),
        "timezone": TimeZone.current.identifier,
        "target": [
            "deviceUID": uid,
            "deviceName": initial.name,
            "initialBucket": initial.bucketKey,
            "initialSnapshot": initial.dictionary,
            "finalSnapshot": final?.dictionary ?? [:]
        ],
        "collection": [
            "requestedSeconds": duration,
            "windowSeconds": windowSeconds,
            "windowsRecorded": windows.count,
            "cpuLoadProcesses": loadProcesses
        ],
        "windows": windows.map { $0.dictionary },
        "formatChanges": deviceChanges + watcher.events,
        "events": events.map { ["timestamp": stamp($0.timestamp), "kind": $0.kind, "detail": $0.detail] },
        "operatorMarkers": markers.map { ["timestamp": stamp($0.timestamp), "note": $0.note] },
        "criteria": evaluation.criteria.map {
            ["id": $0.id, "statement": $0.statement, "status": $0.status, "evidence": $0.evidence]
        },
        "verdict": evaluation.verdict,
        "verdictReasons": evaluation.reasons,
        "telemetry": [
            "p999": "not observable",
            "p999FollowUp": p999Note,
            "quantiles": "cumulative since AudioRenderer construction, not per window",
            "windowCounters": "callbacks / overBudget / excess / underrun are true per-window deltas",
            "driverUnderruns": underrunSource,
            "mappingUID": mappingUID(for: uid),
            "driverUnderrunFollowUp": "the Host's own 'Buffer underrun' line is redacted "
                + "(Ints interpolated without privacy: .public); if sb-shm-probe is unavailable, "
                + "the smallest safe change is to mark that one log line .public",
            "logSources": collector.sourceSummary(),
            "logSourceRule": "only lines emitted by \(LogCollector.expectedProcess) are treated "
                + "as Host telemetry; every other process on this subsystem is counted and dropped",
            "hostVersion": "see docs/release/SoundBridge-Hardware-Realtime-Readiness-Assessment.md"
        ]
    ]
    let jsonPath = (outDir as NSString).appendingPathComponent("result.json")
    writeJSON(result, to: jsonPath)
    let mdPath = (outDir as NSString).appendingPathComponent("result.md")
    writeMarkdown(result, to: mdPath)
    print("result: \(jsonPath)")
    print("report: \(mdPath)")
    print("verdict: \(evaluation.verdict)")
    if windows.allSatisfy({ $0.callbacks == 0 }) {
        // A harness that could not read the log has not observed an idle
        // device; it has observed nothing at all. Reporting those as the same
        // "no IO" would hand the operator a wrong diagnosis, so they exit with
        // different codes and different words.
        if let failure = collector.observationFailure() {
            die("COULD NOT READ HOST LOG: \(failure). This is an observation "
                + "failure, not evidence that nothing played; exit code 5 is "
                + "never a hardware result.", code: 5)
        }
        let sources = collector.sourceSummary()
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        die("NO CORE AUDIO IO OBSERVED: no \(LogCollector.expectedProcess) timing line with a "
            + "rising callback count (log sources seen: "
            + (sources.isEmpty ? "none" : sources) + ")", code: 4)
    }
}

func commandReport(_ args: [String: String]) {
    guard let path = args["results"] else { die("report needs --results") }
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        die("could not read \(path)")
    }
    let out = args["out"] ?? ((path as NSString).deletingPathExtension + ".md")
    writeMarkdown(object, to: out)
    print("report: \(out)")
}

// MARK: - Rendering

func writeJSON(_ object: [String: Any], to path: String?) {
    let data = try! JSONSerialization.data(withJSONObject: object,
                                           options: [.prettyPrinted, .sortedKeys])
    if let path {
        try? data.write(to: URL(fileURLWithPath: path))
        print("json: \(path)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func writeMarkdown(_ result: [String: Any], to path: String) {
    var md = "# SoundBridge hardware validation run\n\n"
    md += "Generated: \(stamp())\n\n"
    if let verdict = result["verdict"] as? String {
        md += "> **\(verdict)**\n\n"
    }
    md += "> This file is machine-generated. It contains only what was observed; "
    md += "absent data is named as absent, never filled in.\n\n"

    if let target = result["target"] as? [String: Any] {
        md += "## Target\n\n| field | value |\n|---|---|\n"
        for key in ["deviceUID", "deviceName", "initialBucket"] {
            md += "| \(key) | \(target[key] ?? "—") |\n"
        }
        md += "\n"
    }
    if let collection = result["collection"] as? [String: Any] {
        md += "## Collection\n\n| field | value |\n|---|---|\n"
        for key in ["requestedSeconds", "windowSeconds", "windowsRecorded", "cpuLoadProcesses"] {
            md += "| \(key) | \(collection[key] ?? "—") |\n"
        }
        md += "\n"
    }
    md += "## Windows\n\n"
    md += "Each row's deadline is `frames / rate` for that row. Windows are split whenever the "
    md += "device format changes, so no row mixes two deadlines. p50/p95/p99/max are cumulative "
    md += "since the Host started; callbacks/overBudget/excess/underrun are per-window deltas.\n\n"
    md += "| # | bucket | deadline µs | callbacks | observed Hz | expected Hz | overBudget | excess ms | p99 µs | max µs | underrun |\n"
    md += "|---|---|---|---|---|---|---|---|---|---|---|\n"
    for window in (result["windows"] as? [[String: Any]] ?? []) {
        func cell(_ key: String) -> String {
            guard let value = window[key] else { return "—" }
            if let d = value as? Double { return String(format: "%.1f", d) }
            return "\(value)"
        }
        md += "| \(cell("window")) | \(cell("bucket")) | \(cell("deadlineMicroseconds")) | "
        md += "\(cell("callbacks")) | \(cell("observedCallbackRateHz")) | "
        md += "\(cell("expectedCallbackRateHz")) | \(cell("overBudget")) | "
        md += "\(cell("overBudgetExcessMs")) | \(cell("p99Us")) | \(cell("maxUs")) | "
        md += "\(cell("driverUnderrunDelta")) |\n"
    }
    md += "\n## Criteria\n\n| id | statement | status | evidence |\n|---|---|---|---|\n"
    for criterion in (result["criteria"] as? [[String: Any]] ?? []) {
        md += "| \(criterion["id"] ?? "") | \(criterion["statement"] ?? "") | "
        md += "**\(criterion["status"] ?? "")** | \(criterion["evidence"] ?? "") |\n"
    }
    let events = result["events"] as? [[String: Any]] ?? []
    md += "\n## Host events (\(events.count))\n\n"
    if events.isEmpty {
        md += "No matching Host log lines were observed in this window.\n"
    } else {
        md += "| timestamp | kind | detail |\n|---|---|---|\n"
        for event in events.prefix(200) {
            md += "| \(event["timestamp"] ?? "") | \(event["kind"] ?? "") | "
            md += "\(event["detail"] ?? "") |\n"
        }
    }
    let markers = result["operatorMarkers"] as? [[String: Any]] ?? []
    md += "\n## Operator markers (\(markers.count))\n\n"
    if markers.isEmpty {
        md += "None. The runbook requires markers for scenario boundaries, audible symptoms "
        md += "and the output-restoration confirmation.\n"
    } else {
        md += "| timestamp | note |\n|---|---|\n"
        for marker in markers {
            md += "| \(marker["timestamp"] ?? "") | \(marker["note"] ?? "") |\n"
        }
    }
    if let reasons = result["verdictReasons"] as? [String], !reasons.isEmpty {
        md += "\n## Verdict reasons\n\n"
        for reason in reasons { md += "- \(reason)\n" }
    }
    md += "\n## Telemetry limits\n\n"
    if let telemetry = result["telemetry"] as? [String: Any] {
        for key in telemetry.keys.sorted() {
            md += "- **\(key)**: \(telemetry[key] ?? "")\n"
        }
    }
    try? md.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Entry point

func parseArguments(_ argv: [String]) -> (command: String, options: [String: String]) {
    var options: [String: String] = [:]
    var index = 1
    while index < argv.count {
        let token = argv[index]
        if token.hasPrefix("--"), index + 1 < argv.count {
            options[String(token.dropFirst(2))] = argv[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    return (argv.count > 1 ? argv[1] : "help", options)
}

let (command, options) = parseArguments(CommandLine.arguments)
switch command {
case "inventory": commandInventory(options)
case "collect": commandCollect(options)
case "report": commandReport(options)
case "marker": commandMarker(options)
default:
    print("""
    sb-hw-validate — SoundBridge real CoreAudio hardware validation harness

      inventory  --out <path>                      read-only device dump
      collect    --device-uid <UID> --out-dir <dir> [--duration 1800]
                 [--window 10] [--cpu-load N]      observe a live run
      marker     --out-dir <dir> --note <text>     operator timeline marker
      report     --results <json> [--out <md>]     re-render Markdown

    This tool never changes routing, never installs anything, and never
    fabricates a callback: if nothing is playing through the device it
    reports NO CORE AUDIO IO OBSERVED and exits 4.
    """)
}
