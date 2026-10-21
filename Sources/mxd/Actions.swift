import AppKit
import CoreGraphics

// Private SkyLight (CoreGraphics) calls, read-only, used to locate the current Space.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

enum Actions {
    private static let keyLeft: CGKeyCode = 123
    private static let keyRight: CGKeyCode = 124
    private static let keyLeftBracket: CGKeyCode = 33
    private static let keyRightBracket: CGKeyCode = 30

    /// Set while a multi-step wrap-around is being played, so presses during it are ignored.
    private static var cycling = false

    static func perform(_ name: String) {
        switch name {
        case "mission_control": missionControl()
        case "cycle_desktops": cycleDesktop()
        case "none", "passthrough": break
        default: log("unknown action \(name)")
        }
    }

    static func missionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { log("mission control: \(err)") }
        }
    }

    static func browserBack() { sendShortcut(keyLeftBracket, flags: .maskCommand) }
    static func browserForward() { sendShortcut(keyRightBracket, flags: .maskCommand) }

    /// Move to the next Space on the active display; from the last one, wrap back to the first.
    static func cycleDesktop() {
        if cycling { return }
        guard let (index, count) = currentSpacePosition() else {
            sendShortcut(keyRight, flags: [.maskControl, .maskSecondaryFn])
            return
        }
        if index < count - 1 {
            sendShortcut(keyRight, flags: [.maskControl, .maskSecondaryFn])
            return
        }
        // Wrap around: step left (count - 1) times. Each switch animates, so space the
        // key presses out a little and stop early if we already reached the first Space.
        cycling = true
        stepLeft(remaining: count - 1)
    }

    private static func stepLeft(remaining: Int) {
        guard remaining > 0, let (index, _) = currentSpacePosition(), index > 0 else {
            cycling = false
            return
        }
        sendShortcut(keyLeft, flags: [.maskControl, .maskSecondaryFn])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            stepLeft(remaining: remaining - 1)
        }
    }

    /// (index of the active Space, number of Spaces) on the display that holds the active Space.
    private static func currentSpacePosition() -> (Int, Int)? {
        let cid = CGSMainConnectionID()
        let active = CGSGetActiveSpace(cid)
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value
                ?? ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            if let i = ids.firstIndex(of: active) { return (i, ids.count) }
        }
        return nil
    }

    static func sendShortcut(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
