import AppKit
import CoreGraphics

/// Intercepts middle / back / forward mouse buttons.
final class ButtonTap {
    private let config: Config
    private var tap: CFMachPort?
    /// Buttons whose mouse-down we swallowed, so the matching mouse-up is swallowed too.
    private var swallowed = Set<Int64>()

    init(config: Config) { self.config = config }

    func start() -> Bool {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ctx in
                let me = Unmanaged<ButtonTap>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: me
        ) else {
            log("event tap creation failed (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap installed")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("event tap re-enabled")
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let isDown = type == .otherMouseDown

        if !isDown {
            return swallowed.remove(button) != nil ? nil : Unmanaged.passUnretained(event)
        }

        let handled: Bool = autoreleasepool {
            switch button {
            case 2:
                guard config.middle != "passthrough" else { return false }
                Actions.perform(config.middle)
                return true
            case 3, 4:
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                guard config.backForward.keyboardNavApps.contains(front) else { return false }
                if button == 3 { Actions.browserBack() } else { Actions.browserForward() }
                return true
            default:
                return false
            }
        }
        if handled {
            swallowed.insert(button)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
