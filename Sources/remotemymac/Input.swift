import Foundation
import CoreGraphics
import ApplicationServices

/// Injects mouse / keyboard / scroll events. Requires the Accessibility permission.
final class InputInjector {
    private let src = CGEventSource(stateID: .hidSystemState)
    private var down = Set<UInt16>()
    private var buttonsDown = Set<Int>()
    private var rem = CGPoint.zero      // sub-point remainder for relative movement

    private var actual: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    var bounds: CGRect { CGDisplayBounds(VirtualDisplay.target) }

    private func point(_ o: [String: Any]) -> CGPoint {
        let b = bounds
        // No coordinates (e.g. button release while the pointer is locked): stay exactly where the cursor is.
        guard let nx = o["x"] as? Double, let ny = o["y"] as? Double else { return actual }
        let x = min(max(nx, 0), 1), y = min(max(ny, 0), 1)
        return CGPoint(x: b.origin.x + x * (b.width - 1), y: b.origin.y + y * (b.height - 1))
    }

    private func flags(_ o: [String: Any]) -> CGEventFlags {
        let f = (o["f"] as? Int) ?? 0
        var r = CGEventFlags()
        if f & 1 != 0 { r.insert(.maskShift) }
        if f & 2 != 0 { r.insert(.maskControl) }
        if f & 4 != 0 { r.insert(.maskAlternate) }
        if f & 8 != 0 { r.insert(.maskCommand) }
        return r
    }

    func handle(_ t: String, _ o: [String: Any]) {
        let p = point(o)
        let btn = (o["b"] as? Int) ?? 0
        switch t {
        case "m":
            let type: CGEventType = buttonsDown.contains(0) ? .leftMouseDragged : buttonsDown.contains(2) ? .rightMouseDragged
                : buttonsDown.contains(1) ? .otherMouseDragged : .mouseMoved
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(buttonsDown.first ?? 0))
            let cur = actual
            // Real deltas for normal movement; big jumps (e.g. after pointer lock ends) must not look like camera motion.
            let ddx = (p.x - cur.x).rounded(), ddy = (p.y - cur.y).rounded()
            let small = abs(ddx) <= 80 && abs(ddy) <= 80
            e?.setIntegerValueField(.mouseEventDeltaX, value: small ? Int64(ddx) : 0)
            e?.setIntegerValueField(.mouseEventDeltaY, value: small ? Int64(ddy) : 0)
            post(e, o)
        case "r":      // relative movement (browser pointer lock): start from the REAL cursor, which games re-centre
            let b = bounds
            let fx = ((o["dx"] as? Double) ?? 0) * b.width + rem.x, fy = ((o["dy"] as? Double) ?? 0) * b.height + rem.y
            let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
            rem = CGPoint(x: fx - ix, y: fy - iy)
            let cur = actual
            let np = CGPoint(x: min(max(cur.x + ix, b.minX), b.maxX - 1), y: min(max(cur.y + iy, b.minY), b.maxY - 1))
            let type: CGEventType = buttonsDown.contains(0) ? .leftMouseDragged : buttonsDown.contains(2) ? .rightMouseDragged
                : buttonsDown.contains(1) ? .otherMouseDragged : .mouseMoved
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: np, mouseButton: cgButton(buttonsDown.first ?? 0))
            e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
            e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
            post(e, o)
        case "d", "u":
            let isDown = t == "d"
            if isDown { buttonsDown.insert(btn) } else { buttonsDown.remove(btn) }
            let type: CGEventType = btn == 0 ? (isDown ? .leftMouseDown : .leftMouseUp)
                : btn == 2 ? (isDown ? .rightMouseDown : .rightMouseUp) : (isDown ? .otherMouseDown : .otherMouseUp)
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(btn))
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(min(max((o["c"] as? Int) ?? 1, 1), 3)))
            post(e, o)
        case "w":
            let dx = Int32(max(-2000, min(2000, (o["dx"] as? Double) ?? 0)))
            let dy = Int32(max(-2000, min(2000, (o["dy"] as? Double) ?? 0)))
            post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0), o)
        case "k":
            guard let code = o["code"] as? String else { return }
            let isDown = (o["d"] as? Int) == 1
            if let kc = InputInjector.keymap[code] {
                if isDown { down.insert(kc) } else { down.remove(kc) }
                post(CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: isDown), o)
            } else if isDown, let k = o["key"] as? String, k.count == 1 {      // unmapped printable char: type it directly
                let u = Array(k.utf16)
                for d in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: d)
                    e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                    e?.post(tap: .cghidEventTap)
                }
            }
        case "release": releaseAll()
        default: break
        }
    }

    /// Release everything held (called on disconnect so keys/buttons never stay stuck).
    func releaseAll() {
        for kc in down { CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)?.post(tap: .cghidEventTap) }
        down.removeAll()
        let pos = CGEvent(source: nil)?.location ?? .zero
        for b in buttonsDown {
            let type: CGEventType = b == 0 ? .leftMouseUp : b == 2 ? .rightMouseUp : .otherMouseUp
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton(b))?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
    }

    private func cgButton(_ b: Int) -> CGMouseButton { b == 0 ? .left : b == 2 ? .right : .center }

    private func post(_ e: CGEvent?, _ o: [String: Any]) {
        guard let e else { return }
        e.flags = flags(o)
        e.post(tap: .cghidEventTap)
    }

    static let keymap: [String: UInt16] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9,
        "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
        "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25,
        "Digit7": 26, "Minus": 27, "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32,
        "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40,
        "Semicolon": 41, "Backslash": 42, "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48,
        "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53, "MetaRight": 54, "MetaLeft": 55, "ShiftLeft": 56,
        "CapsLock": 57, "AltLeft": 58, "ControlLeft": 59, "ShiftRight": 60, "AltRight": 61, "ControlRight": 62,
        "NumpadEnter": 76, "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103, "F10": 109,
        "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120, "PageDown": 121,
        "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
    ]
}
