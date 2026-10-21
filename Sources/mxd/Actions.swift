import AppKit
import CoreGraphics

// Private SkyLight (CoreGraphics) calls, read-only, used to locate the current Space.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
private func CGSCopyActiveMenuBarDisplayIdentifier(_ cid: Int32) -> Unmanaged<CFString>?

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

    /// Move to the next Space on the display under the cursor; from the last one, wrap back to the first.
    static func cycleDesktop() {
        if cycling { return }
        let target = cursorDisplayID()
        guard let pos = spacePosition(display: target) else {
            log("cycle: no space info, sending ctrl+right")
            sendShortcut(keyRight, flags: [.maskControl, .maskSecondaryFn])
            return
        }
        log("cycle: cursor display \(target ?? "?") space \(pos.index + 1)/\(pos.count), menu bar display \(menuBarDisplayID() ?? "?")")
        if pos.count <= 1 { return }
        if pos.index < pos.count - 1 {
            sendShortcut(keyRight, flags: [.maskControl, .maskSecondaryFn])
            return
        }
        // Wrap around: step left (count - 1) times. Each switch animates, so space the
        // key presses out a little and stop early if we already reached the first Space.
        cycling = true
        stepLeft(remaining: pos.count - 1, display: target)
    }

    private static func stepLeft(remaining: Int, display: String?) {
        guard remaining > 0, let pos = spacePosition(display: display), pos.index > 0 else {
            cycling = false
            return
        }
        sendShortcut(keyLeft, flags: [.maskControl, .maskSecondaryFn])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            stepLeft(remaining: remaining - 1, display: display)
        }
    }

    /// UUID string of the display containing the mouse cursor (matches "Display Identifier").
    static func cursorDisplayID() -> String? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &n) == .success, n > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func menuBarDisplayID() -> String? {
        CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID())?.takeRetainedValue() as String?
    }

    /// Position of the current Space within the given display's Spaces. Falls back to the display
    /// holding the active Space when the display isn't found (e.g. "Displays have separate Spaces" off).
    private static func spacePosition(display: String?) -> (index: Int, count: Int)? {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        func spaceID(_ d: [String: Any]?) -> UInt64? {
            (d?["id64"] as? NSNumber)?.uint64Value ?? (d?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }
        func position(_ d: [String: Any], current: UInt64) -> (Int, Int)? {
            let ids = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { spaceID($0) }
            return ids.firstIndex(of: current).map { ($0, ids.count) }
        }
        if let display,
           let d = displays.first(where: { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(display) == .orderedSame }),
           let current = spaceID(d["Current Space"] as? [String: Any]) {
            return position(d, current: current)
        }
        let active = CGSGetActiveSpace(cid)
        for d in displays {
            if let p = position(d, current: active) { return p }
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
