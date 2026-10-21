import AppKit
import ApplicationServices
import IOKit.hid
import os

private let logger = Logger(subsystem: "com.winniesi.mxd", category: "main")
private let verbose = CommandLine.arguments.contains("--verbose")

func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    if verbose { print(message) }
}

setvbuf(stdout, nil, _IOLBF, 0)

let config = Config.load()
log("mxd starting: modeShift=\(config.modeShift) middle=\(config.middle) wheel=\(config.wheel) dpi=\(config.dpi.map(String.init) ?? "unchanged")")

// Permissions: Accessibility (event tap + synthetic keys) and Input Monitoring (HID device access).
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
if !trusted { log("Accessibility permission not granted yet") }
if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
    log("Input Monitoring permission not granted yet")
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
}

let hidpp = MainActor.assumeIsolated { HIDPPManager(config: config) }
MainActor.assumeIsolated { hidpp.start() }

let buttons = ButtonTap(config: config)
if !buttons.start() {
    // Without Accessibility the tap can't be created; launchd restarts us, so retry later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(1) }
}

let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    log("system woke, re-applying settings")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        MainActor.assumeIsolated { hidpp.reapply() }
    }
}

signal(SIGTERM) { _ in exit(0) }
CFRunLoopRun()
