import Foundation
import IOKit.hid

// HID++ 2.0 over the device's vendor reports. Only long reports (0x11) are sent:
// Bluetooth LE Logitech devices don't accept short ones.
private let reportShort: UInt8 = 0x10
private let reportLong: UInt8 = 0x11
private let deviceIndexDirect: UInt8 = 0xFF   // Bluetooth / USB direct connection
private let softwareID: UInt8 = 0x0B
private let inputBufferSize = 64

private enum Feature: UInt16 {
    case root = 0x0000
    case reprogControlsV4 = 0x1B04
    case smartShift = 0x2110
    case smartShiftEnhanced = 0x2111
    case adjustableDPI = 0x2201
}

private let cidModeShift: UInt16 = 0x00C4

@MainActor
final class HIDPPDevice {
    let device: IOHIDDevice
    let name: String
    private let config: Config
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)

    private var reprogIndex: UInt8 = 0
    private var pressedCIDs = Set<UInt16>()

    private struct Pending {
        let token: UInt64
        let feature: UInt8
        let fnSw: UInt8
        let continuation: CheckedContinuation<[UInt8]?, Never>
    }
    private var pending: Pending?
    private var nextToken: UInt64 = 0

    init(device: IOHIDDevice, name: String, config: Config) {
        self.device = device
        self.name = name
        self.config = config
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, inputBufferSize, { ctx, _, _, _, reportID, report, length in
            guard let ctx, reportID == UInt32(reportLong) || reportID == UInt32(reportShort) else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(ctx).takeUnretainedValue()
            // The buffer normally starts with the report ID; normalise in case it doesn't.
            var msg = Array(UnsafeBufferPointer(start: report, count: length))
            if msg.first != UInt8(reportID) { msg.insert(UInt8(reportID), at: 0) }
            MainActor.assumeIsolated { me.handle(msg) }
        }, ctx)
    }

    /// Must be called before the object is dropped, so the callback never sees a dangling context.
    func invalidate() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, inputBufferSize, nil, nil)
        if let p = pending { pending = nil; p.continuation.resume(returning: nil) }
    }

    deinit { buffer.deallocate() }

    // MARK: - Requests

    private func request(_ feature: UInt8, _ fn: UInt8, _ params: [UInt8] = [], timeout: Double = 1.0) async -> [UInt8]? {
        if pending != nil { return nil }   // strictly sequential by construction
        nextToken &+= 1
        let token = nextToken
        let fnSw = (fn << 4) | softwareID
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = reportLong
        report[1] = deviceIndexDirect
        report[2] = feature
        report[3] = fnSw
        for (i, b) in params.prefix(16).enumerated() { report[4 + i] = b }

        return await withCheckedContinuation { cont in
            pending = Pending(token: token, feature: feature, fnSw: fnSw, continuation: cont)
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportLong), report, report.count)
            if r != kIOReturnSuccess {
                log("\(name): send failed 0x\(String(UInt32(bitPattern: r), radix: 16))")
                finish(token, nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pending?.token == token else { return }
                    log("\(self.name): timeout feature=\(feature) fn=\(fn)")
                    self.finish(token, nil)
                }
            }
        }
    }

    private func finish(_ token: UInt64, _ value: [UInt8]?) {
        guard let p = pending, p.token == token else { return }
        pending = nil
        p.continuation.resume(returning: value)
    }

    private func featureIndex(_ f: Feature) async -> UInt8? {
        guard let r = await request(0x00, 0, [UInt8(f.rawValue >> 8), UInt8(f.rawValue & 0xFF)]) else { return nil }
        return r[0] == 0 ? nil : r[0]
    }

    // MARK: - Setup

    /// Returns false if the device didn't speak HID++ at all (wrong HID interface).
    func applySettings() async -> Bool {
        guard await request(0x00, 1) != nil else { return false }   // root.getProtocolVersion

        if let idx = await featureIndex(.reprogControlsV4) {
            reprogIndex = idx
            if config.modeShift != "none" {
                // setCidReporting: divert + dvalid, no remap
                let ok = await request(idx, 3, [UInt8(cidModeShift >> 8), UInt8(cidModeShift & 0xFF), 0x03, 0, 0]) != nil
                log("\(name): divert mode-shift button (reprog idx \(idx)) \(ok ? "ok" : "FAILED")")
            }
        } else {
            log("\(name): REPROG_CONTROLS_V4 not found")
        }

        if config.wheel != "unchanged" {
            let mode: UInt8 = config.wheel == "ratchet" ? 2 : 1
            let disengage: UInt8 = config.wheel == "ratchet" ? 0xFF : 0
            if let idx = await featureIndex(.smartShiftEnhanced) {
                let ok = await request(idx, 2, [mode, disengage, 0]) != nil
                log("\(name): wheel \(config.wheel) (0x2111 idx \(idx)) \(ok ? "ok" : "FAILED")")
            } else if let idx = await featureIndex(.smartShift) {
                let ok = await request(idx, 1, [mode, disengage, 0]) != nil
                log("\(name): wheel \(config.wheel) (0x2110 idx \(idx)) \(ok ? "ok" : "FAILED")")
            } else {
                log("\(name): SMART_SHIFT not found")
            }
        }

        if let dpi = config.dpi, dpi > 0 {
            if let idx = await featureIndex(.adjustableDPI) {
                let ok = await request(idx, 3, [0, UInt8((dpi >> 8) & 0xFF), UInt8(dpi & 0xFF)]) != nil
                log("\(name): dpi \(dpi) (idx \(idx)) \(ok ? "ok" : "FAILED")")
            } else {
                log("\(name): ADJUSTABLE_DPI not found")
            }
        }
        return true
    }

    // MARK: - Incoming

    private func handle(_ msg: [UInt8]) {
        guard msg.count >= 7, msg[1] == deviceIndexDirect else { return }
        let feature = msg[2], fnSw = msg[3]

        if feature == 0xFF, msg.count >= 6 {   // HID++ 2.0 error: [.., 0xFF, feature, fnSw, code]
            if let p = pending, p.feature == msg[3], p.fnSw == msg[4] {
                log("\(name): error \(msg[5]) for feature=\(msg[3]) fn=\(msg[4] >> 4)")
                finish(p.token, nil)
            }
            return
        }
        if let p = pending, p.feature == feature, p.fnSw == fnSw {
            finish(p.token, Array(msg[4...]))
            return
        }
        // Notification (software ID 0). divertedButtonsEvent = event 0 of REPROG_CONTROLS_V4.
        if fnSw & 0x0F == 0, reprogIndex != 0, feature == reprogIndex, fnSw >> 4 == 0 {
            var now = Set<UInt16>()
            var i = 4
            while i + 1 < msg.count {
                let cid = UInt16(msg[i]) << 8 | UInt16(msg[i + 1])
                if cid == 0 { break }
                now.insert(cid)
                i += 2
            }
            let newlyPressed = now.subtracting(pressedCIDs)
            pressedCIDs = now
            if newlyPressed.contains(cidModeShift) {
                Actions.perform(config.modeShift)
            }
        }
    }
}

/// Watches for the mouse to appear / disappear and keeps exactly one active HID++ session.
@MainActor
final class HIDPPManager {
    private let config: Config
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var active: HIDPPDevice?
    private var candidates: [IOHIDDevice] = []
    private var probing = false

    init(config: Config) { self.config = config }

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDPPManager>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDPPManager>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            log("IOHIDManagerOpen failed 0x\(String(UInt32(bitPattern: r), radix: 16)) (Input Monitoring permission missing?)")
        }
    }

    /// Re-apply settings, e.g. after the Mac wakes up.
    func reapply() {
        guard let dev = active else { return }
        Task { @MainActor in _ = await dev.applySettings() }
    }

    private static func product(_ d: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    }

    private func added(_ device: IOHIDDevice) {
        let name = Self.product(device)
        guard name.localizedCaseInsensitiveContains("MX Anywhere") else { return }
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        log("matched \(name) (usage page 0x\(String(page, radix: 16)))")
        // Vendor-page interfaces first: that's where HID++ normally lives.
        if page >= 0xFF00 { candidates.insert(device, at: 0) } else { candidates.append(device) }
        probeNext()
    }

    private func removed(_ device: IOHIDDevice) {
        candidates.removeAll { $0 === device }
        if let a = active, a.device === device {
            log("\(a.name) disconnected")
            a.invalidate()
            active = nil
        }
    }

    private func probeNext() {
        guard active == nil, !probing, !candidates.isEmpty else { return }
        probing = true
        let device = candidates.removeFirst()
        let dev = HIDPPDevice(device: device, name: Self.product(device), config: config)
        Task { @MainActor in
            // Give a freshly (re)connected Bluetooth device a moment before talking to it.
            try? await Task.sleep(nanoseconds: 500_000_000)
            let ok = await dev.applySettings()
            self.probing = false
            if ok {
                self.active = dev
                self.candidates.removeAll()
                log("\(dev.name) ready")
            } else {
                dev.invalidate()
                log("\(dev.name): no HID++ on this interface")
                self.probeNext()
            }
        }
    }
}
