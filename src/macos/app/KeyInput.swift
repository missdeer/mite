import AppKit

// Mirrors the `Key` enum in capi.zig — values must stay in sync.
enum MosttyKey: UInt32 {
    case up = 0, down = 1, right = 2, left = 3
    case home = 4, end = 5, pageUp = 6, pageDown = 7
    case insert = 8, delete = 9, enter = 10, tab = 11, backspace = 12, escape = 13
    case f1 = 14, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

enum KeyInput {
    static let modShift: UInt32 = 1
    static let modAlt: UInt32 = 2
    static let modCtrl: UInt32 = 4

    /// Map a macOS virtual key code to a terminal special key, or nil for keys
    /// that carry text (and should flow through the input context / IME).
    static func specialKey(_ keyCode: UInt16) -> MosttyKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .delete
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        default: return nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= modShift }
        if flags.contains(.option) { m |= modAlt }
        if flags.contains(.control) { m |= modCtrl }
        return m
    }

    /// Bytes for a character key modified by Control and/or Option. Control maps
    /// ASCII 0x40..0x7f to their C0 control code; Option acts as Meta, prefixing
    /// ESC. Returns nil when the event carries no usable base character.
    static func controlMetaBytes(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control)
        let meta = flags.contains(.option)
        guard ctrl || meta else { return nil }
        guard let base = event.charactersIgnoringModifiers,
              let scalar = base.unicodeScalars.first else { return nil }

        var out: [UInt8] = []
        if meta { out.append(0x1b) }

        if ctrl {
            let v = scalar.value
            if v == 0x20 || v == 0x32 { // Space or '2' => NUL
                out.append(0)
            } else if v >= 0x40 && v < 0x80 {
                out.append(UInt8(v & 0x1f))
            } else {
                return meta ? out : nil
            }
        } else {
            out.append(contentsOf: Array(base.utf8))
        }
        return out.isEmpty ? nil : out
    }

    /// Remove every embedded bracketed-paste end marker (`ESC [ 2 0 1 ~`) from
    /// pasted bytes so the payload can't close paste mode early.
    static func stripPasteEnd(_ bytes: [UInt8]) -> [UInt8] {
        let marker: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
        // Fast path: without an ESC there is nothing to strip, which is the
        // common case for plain-text pastes and avoids scanning at all.
        guard bytes.count >= marker.count, bytes.contains(marker[0]) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == marker[0] && matchesMarker(bytes, at: i, marker) {
                i += marker.count
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func matchesMarker(_ bytes: [UInt8], at i: Int, _ marker: [UInt8]) -> Bool {
        guard i + marker.count <= bytes.count else { return false }
        var k = 1
        while k < marker.count {
            if bytes[i + k] != marker[k] { return false }
            k += 1
        }
        return true
    }
}
