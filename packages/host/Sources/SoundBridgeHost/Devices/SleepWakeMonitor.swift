import Foundation
import IOKit
import IOKit.pwr_mgt

// IOKit message constants not exposed through the Swift IOKit module overlay
private let kIOMessageSystemWillSleepValue: UInt32 = 0xe0000280
private let kIOMessageSystemHasPoweredOnValue: UInt32 = 0xe0000300

class SleepWakeMonitor {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    private let lifecycleGate: HostLifecycleGate
    private var isRunning = false
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifyIterator: io_object_t = 0

    init(lifecycleGate: HostLifecycleGate = HostLifecycleGate()) {
        self.lifecycleGate = lifecycleGate
    }

    func start() {
        guard !isRunning else { return }
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notifyPort,
            sleepWakeCallbackC,
            &notifyIterator
        )
        guard rootPort != 0, let port = notifyPort else {
            print("[SleepWake] ERROR: IORegisterForSystemPower failed")
            return
        }
        // IONotificationPortGetRunLoopSource is a "Get" function — caller does not own the result
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(RunLoop.current.getCFRunLoop(), source, CFRunLoopMode.commonModes)
        }
        isRunning = true
        print("[SleepWake] Registered for sleep/wake notifications")
    }

    func stop() {
        isRunning = false
        if let port = notifyPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(RunLoop.current.getCFRunLoop(), source, CFRunLoopMode.commonModes)
            }
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if notifyIterator != 0 {
            IOObjectRelease(notifyIterator)
            notifyIterator = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    fileprivate func handleMessage(_ messageType: UInt32, messageArg: UnsafeMutableRawPointer?) {
        switch messageType {
        case kIOMessageSystemWillSleepValue:
            print("[SleepWake] System will sleep")
            onSleep?()
            if rootPort != 0, let messageArg {
                IOAllowPowerChange(rootPort, Int(bitPattern: messageArg))
            }

        case kIOMessageSystemHasPoweredOnValue:
            guard isRunning, let token = lifecycleGate.normalToken() else { return }
            print("[SleepWake] System did wake — scheduling recovery in \(SoundBridgeConfig.wakeRecoveryDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + SoundBridgeConfig.wakeRecoveryDelay) { [weak self] in
                guard let self, self.isRunning, self.lifecycleGate.permitsNormal(token) else { return }
                self.onWake?()
            }

        default:
            break
        }
    }
}

// File-level C callback — no captures, stable function pointer
private func sleepWakeCallbackC(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArg: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<SleepWakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .handleMessage(messageType, messageArg: messageArg)
}
