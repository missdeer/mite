import AppKit

@main
struct ClipboardTests {
    static func main() {
        exit(run())
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }

        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        func clipboard(_ text: String) {
            pasteboard.clearContents()
            precondition(pasteboard.setString(text, forType: .string), "System pasteboard is unavailable")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MosttyTerminalView(frame: window.contentView!.bounds)
        window.contentView = view
        defer { view.shutdown() }
        // Force grid synchronization without running timers or the fake EOF callback.
        view.setFrameSize(NSSize(width: 410, height: 200))
        view.resyncSurface()

        let start = "\u{1b}[200~", end = "\u{1b}[201~"
        let cases: [(String, String)] = [
            ("first\r\nsecond\nthird\rfourth", "first\rsecond\rthird\rfourth"),
            ("\r\n\n\r\r\n", "\r\r\r\r"),
            ("", ""),
            ("\u{4e2d}\u{1f642}e\u{301}\t", "\u{4e2d}\u{1f642}e\u{301}\t"),
            ("a\r\(end)\nb", "a\r\(end)\rb"),
        ]
        for bracketed in [false, true] {
            for (index, pair) in cases.enumerated() {
                clipboard_test_reset(bracketed)
                clipboard(pair.0)
                view.paste(nil)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = clipboard_test_written(&bytes, bytes.count)
                let expected = bracketed
                    ? start + pair.1.replacingOccurrences(of: end, with: "") + end
                    : pair.1
                expect(Array(bytes.prefix(n)) == Array(expected.utf8),
                       "paste case \(index), bracketed=\(bracketed): CRLF/LF become CR, preserving text and framing")
            }
        }

        func mouse(_ type: NSEvent.EventType, _ col: Int) -> NSEvent {
            let cell = view.overlayCellPoints
            let point = view.convert(NSPoint(x: (Double(col) + 0.5) * cell.w,
                                             y: Double(view.bounds.height) - cell.h * 0.5), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 0))
        view.mouseDragged(with: mouse(.leftMouseDragged, 2))
        expect(pasteboard.string(forType: .string) == "sentinel", "dragging alone does not copy")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(pasteboard.string(forType: .string) == "hello", "release automatically copies the final selection")
        clipboard("sentinel")
        view.copy(nil)
        expect(pasteboard.string(forType: .string) == "hello", "manual copy still works")
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 0))
        view.mouseUp(with: mouse(.leftMouseUp, 0))
        expect(pasteboard.string(forType: .string) == "sentinel", "a click without selection preserves the clipboard")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(pasteboard.string(forType: .string) == "sentinel", "an unmatched release preserves the clipboard")
        // Return before exiting so clipboard restoration and shutdown run on failure.
        if failures > 0 {
            print("\(failures) clipboard regression checks failed")
        }
        return failures == 0 ? 0 : 1
    }
}
