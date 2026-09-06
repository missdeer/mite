import AppKit
import Metal
import QuartzCore

/// One terminal surface: owns a bridge tab (PTY + renderer), presents frames
/// through a CAMetalLayer, and captures keyboard / mouse / IME input. All bridge
/// calls except the background reader happen on the main thread.
final class MosttyTerminalView: NSView, NSTextInputClient {
    private var tab: OpaquePointer?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var device: MTLDevice?

    private var alive = false
    private var terminated = false
    private var dirty = false

    private var cols: UInt32 = 0
    private var rows: UInt32 = 0
    private var cellWidthPx: UInt32 = 1
    private var cellHeightPx: UInt32 = 1
    private var lastPixelW: UInt32 = 0
    private var lastPixelH: UInt32 = 0

    // Config-derived state the host owns. Fonts and colors live inside the
    // bridge; these two shape AppKit-side behaviour instead.
    private var backgroundOpacity = mostty_config_background_opacity()
    private var renderIntervalMs = max(UInt32(1), mostty_config_render_interval_ms())
    private var translucent: Bool { backgroundOpacity < 1 }

    private var renderTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var readerThread: Thread?
    private let readerDone = DispatchSemaphore(value: 0)
    // Caps how many PTY chunks may be queued on the main thread at once, so
    // sustained high-throughput output can't grow memory without bound.
    private let feedInFlight = DispatchSemaphore(value: 8)
    private let stopLock = NSLock()
    private var stopFlag = false

    // Selection (grid coords, viewport space) and IME composition state.
    private var selStart = (col: 0, row: 0)
    private var selEnd = (col: 0, row: 0)
    private var selecting = false
    private var selectingWord = false
    private var hasSelection = false
    private var urlTrackingArea: NSTrackingArea?
    private var hoveringURL = false
    private var scrollAccum = 0.0
    private var markedText = ""

    private var overlay: OverlayView?

    var onTitleChange: ((String) -> Void)?
    var onExit: (() -> Void)?
    /// Fired after a window-driven resize so sibling tabs can adopt the same
    /// grid immediately, keeping every session consistent with the window.
    var onSurfaceResize: ((UInt32, UInt32, Float) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        let ov = OverlayView(frame: bounds)
        ov.owner = self
        ov.autoresizingMask = [.width, .height]
        addSubview(ov)
        overlay = ov
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isOpaque: Bool { !translucent }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            window.acceptsMouseMovedEvents = true
            setupIfNeeded()
        } else {
            updateURLHover(at: nil)
        }
    }

    override func layout() {
        super.layout()
        setupIfNeeded()
        overlay?.frame = bounds
    }

    private func currentScale() -> CGFloat { window?.backingScaleFactor ?? 2.0 }

    private func pixelSize() -> (w: UInt32, h: UInt32) {
        let scale = currentScale()
        let w = UInt32(max(1.0, Double(bounds.width) * Double(scale)))
        let h = UInt32(max(1.0, Double(bounds.height) * Double(scale)))
        return (w, h)
    }

    private func setupIfNeeded() {
        guard tab == nil, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let scale = currentScale()
        let (pw, ph) = pixelSize()
        guard let t = mostty_tab_create(pw, ph, Float(scale)) else { return }
        tab = t

        guard let devPtr = mostty_tab_metal_device(t),
              let dev = Unmanaged<AnyObject>.fromOpaque(devPtr).takeUnretainedValue() as? MTLDevice,
              let layer = self.layer as? CAMetalLayer else {
            mostty_tab_destroy(t); tab = nil; return
        }
        device = dev
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: Int(pw), height: Int(ph))
        layer.isOpaque = !translucent
        metalLayer = layer
        commandQueue = dev.makeCommandQueue()

        var cw: UInt32 = 1, ch: UInt32 = 1
        mostty_tab_cell_size(t, &cw, &ch)
        cellWidthPx = max(1, cw); cellHeightPx = max(1, ch)
        lastPixelW = pw; lastPixelH = ph

        alive = true
        dirty = true
        startReader(t)
        startTimer()
        startBlink()
        updateTitle()
        window?.makeFirstResponder(self)
    }

    func shutdown() {
        updateURLHover(at: nil)
        guard alive else {
            if let t = tab { mostty_tab_destroy(t); tab = nil }
            return
        }
        alive = false
        setStop(true)
        if readerThread != nil { readerDone.wait() }
        renderTimer?.invalidate(); renderTimer = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        if let t = tab { mostty_tab_destroy(t); tab = nil }
    }

    deinit { shutdown() }

    // MARK: Reader thread

    private func setStop(_ v: Bool) { stopLock.lock(); stopFlag = v; stopLock.unlock() }
    private func getStop() -> Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopFlag }

    private func startReader(_ t: OpaquePointer) {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let cap = 1 << 16
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { buf.deallocate(); self.readerDone.signal() }
            while !self.getStop() {
                let n = mostty_tab_read(t, buf, cap)
                if n == -2 { continue }
                if n <= 0 {
                    DispatchQueue.main.async { self.handleEOF() }
                    break
                }
                let bytes = Array(UnsafeBufferPointer(start: buf, count: Int(n)))
                // Block until a feed slot frees up, re-checking the stop flag so
                // shutdown can't wedge the reader behind a main thread that has
                // stopped draining the queue.
                var acquired = false
                while !acquired {
                    if self.getStop() { break }
                    acquired = self.feedInFlight.wait(timeout: .now() + 0.1) == .success
                }
                if !acquired { break }
                DispatchQueue.main.async {
                    defer { self.feedInFlight.signal() }
                    guard self.alive, let tab = self.tab else { return }
                    bytes.withUnsafeBufferPointer { p in
                        mostty_tab_feed(tab, p.baseAddress, bytes.count)
                    }
                    self.dirty = true
                    self.updateTitle()
                }
            }
        }
        thread.stackSize = 1 << 20
        readerThread = thread
        thread.start()
    }

    private func handleEOF() {
        guard alive, let t = tab, !terminated else { return }
        var code: Int32 = 0
        _ = mostty_tab_poll_exit(t, &code)
        terminated = true
        dirty = true
        onExit?()
    }

    // MARK: Rendering

    private func startTimer() {
        let timer = Timer(timeInterval: Double(renderIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.renderTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    /// Adopt a reloaded config. Fonts and colors are re-applied inside the
    /// bridge; the layer's opacity and the frame cadence are host-owned.
    func applyConfig() {
        backgroundOpacity = mostty_config_background_opacity()
        metalLayer?.isOpaque = !translucent

        // Record the interval even for a tab that has not started yet, so it
        // opens at the configured cadence instead of the one loaded at launch.
        let interval = max(UInt32(1), mostty_config_render_interval_ms())
        if interval != renderIntervalMs {
            renderIntervalMs = interval
            if renderTimer != nil {
                renderTimer?.invalidate()
                startTimer()
            }
        }

        if let t = tab, mostty_tab_apply_config(t) {
            // New cell metrics: the grid no longer matches the drawable, so let
            // the resize path run even though the pixel size is unchanged. The
            // resize itself is deferred to `resyncSurface` on the on-screen tab,
            // because a background tab's bounds and backing scale are stale.
            lastPixelW = 0
            lastPixelH = 0
        }
        dirty = true
        needsDisplay = true
    }

    /// Re-derive the grid from the current drawable and propagate it to sibling
    /// tabs. Called on the on-screen tab after every tab has adopted a reloaded
    /// font, so all sessions land on the same grid instead of background tabs
    /// keeping the old one until they are next shown.
    func resyncSurface() {
        guard window != nil else { return }
        syncSurfaceIfNeeded()
    }

    private func startBlink() {
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // The cursor is drawn into the frame, so re-render on each toggle.
            self.blinkOn.toggle()
            self.dirty = true
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func renderTick() {
        // Background tabs are detached from the window; skip rendering entirely
        // so they don't rasterize at 60 Hz (the blink timer keeps dirty set, and
        // an offscreen layer's nextDrawable can be nil, re-arming dirty forever).
        // The reader still feeds VT state; the next present happens when shown.
        guard window != nil else { return }
        syncSurfaceIfNeeded()
        guard alive, dirty, let t = tab, let layer = metalLayer, let queue = commandQueue else { return }
        let mouse = window?.isKeyWindow == true
            ? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } : nil
        updateURLHover(at: mouse)
        dirty = false
        // Focused cursor blinks; unfocused shows a steady block.
        let focused = window?.firstResponder === self
        let cursorOn = focused ? blinkOn : true
        var c: UInt32 = 0, r: UInt32 = 0
        guard let texPtr = mostty_tab_render(t, cursorOn, &c, &r) else { return }
        cols = c; rows = r
        guard let src = Unmanaged<AnyObject>.fromOpaque(texPtr).takeUnretainedValue() as? MTLTexture else { return }
        guard let drawable = layer.nextDrawable() else { dirty = true; return }
        let dst = drawable.texture
        guard src.width == dst.width, src.height == dst.height else { dirty = true; return }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        overlay?.needsDisplay = true
    }

    private func syncSurfaceIfNeeded() {
        guard alive, let t = tab, let layer = metalLayer else { return }
        let scale = currentScale()
        let (pw, ph) = pixelSize()
        if pw == lastPixelW && ph == lastPixelH { return }
        var nc: UInt32 = 0, nr: UInt32 = 0
        guard mostty_tab_set_surface(t, pw, ph, Float(scale), &nc, &nr) else { return }
        cols = nc; rows = nr
        var cw: UInt32 = 1, ch: UInt32 = 1
        mostty_tab_cell_size(t, &cw, &ch)
        cellWidthPx = max(1, cw); cellHeightPx = max(1, ch)
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: Int(pw), height: Int(ph))
        lastPixelW = pw; lastPixelH = ph
        // Composition is anchored to the cursor; a resize commits it to avoid a
        // dangling overlay.
        commitMarkedIfNeeded()
        dirty = true
        onSurfaceResize?(pw, ph, Float(scale))
    }

    /// Adopt a window-driven size decided by another (active) tab, so this
    /// background session's PTY, VT, and renderer stay consistent immediately.
    func applyExternalSurface(_ pw: UInt32, _ ph: UInt32, _ scale: Float) {
        guard alive, let t = tab, let layer = metalLayer else { return }
        if pw == lastPixelW && ph == lastPixelH { return }
        var nc: UInt32 = 0, nr: UInt32 = 0
        guard mostty_tab_set_surface(t, pw, ph, scale, &nc, &nr) else { return }
        cols = nc; rows = nr
        var cw: UInt32 = 1, ch: UInt32 = 1
        mostty_tab_cell_size(t, &cw, &ch)
        cellWidthPx = max(1, cw); cellHeightPx = max(1, ch)
        layer.contentsScale = CGFloat(scale)
        layer.drawableSize = CGSize(width: Int(pw), height: Int(ph))
        lastPixelW = pw; lastPixelH = ph
        commitMarkedIfNeeded()
        dirty = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dirty = true
    }

    private func updateTitle() {
        guard let t = tab else { return }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = mostty_tab_title(t, &buf, buf.count)
        if n > 0 {
            let title = String(decoding: buf[0..<n], as: UTF8.self)
            onTitleChange?(title)
        }
    }

    // MARK: Writing

    private func writeBytes(_ bytes: [UInt8]) {
        guard let t = tab, !terminated, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { p in mostty_tab_write(t, p.baseAddress, bytes.count) }
    }

    private func writeString(_ s: String) { writeBytes(Array(s.utf8)) }

    private func scrollToBottomOnInput() {
        guard let t = tab else { return }
        mostty_tab_scroll_to_bottom(t)
        blinkOn = true
        dirty = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard tab != nil, !terminated else { return }
        if !markedText.isEmpty {
            inputContext?.handleEvent(event)
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command) { super.keyDown(with: event); return }
        if let key = KeyInput.specialKey(event.keyCode) {
            sendKey(key, flags: flags)
            scrollToBottomOnInput()
            return
        }
        if flags.contains(.control) || flags.contains(.option) {
            if let bytes = KeyInput.controlMetaBytes(event) {
                writeBytes(bytes); scrollToBottomOnInput(); return
            }
        }
        if !(inputContext?.handleEvent(event) ?? false) {
            if let s = event.characters, !s.isEmpty { writeString(s); scrollToBottomOnInput() }
        }
    }

    private func sendKey(_ key: MosttyKey, flags: NSEvent.ModifierFlags) {
        guard let t = tab else { return }
        let app = mostty_tab_app_cursor_keys(t)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = mostty_encode_key(key.rawValue, KeyInput.modifiers(flags), app, &buf, buf.count)
        if n > 0 { writeBytes(Array(buf[0..<n])) }
    }

    // MARK: Mouse

    private func gridCell(at p: NSPoint) -> (col: Int, row: Int) {
        let scale = Double(currentScale())
        let cwPts = Double(cellWidthPx) / scale
        let chPts = Double(cellHeightPx) / scale
        let col = cwPts > 0 ? Int(floor(Double(p.x) / cwPts)) : 0
        // Rows are laid out downward from the top edge, and the renderer keeps a
        // gutter at the bottom, so the row must be measured from the top rather
        // than inferred from the row count.
        let rowFromTop = chPts > 0 ? Int(floor((Double(bounds.height) - Double(p.y)) / chPts)) : 0
        return (col, rowFromTop)
    }

    private func cellAt(_ event: NSEvent) -> (col: Int, row: Int) {
        let cell = gridCell(at: convert(event.locationInWindow, from: nil))
        let clampedCol = min(max(0, cell.col), max(0, Int(cols) - 1))
        let clampedRow = min(max(0, cell.row), max(0, Int(rows) - 1))
        return (clampedCol, clampedRow)
    }

    private func viewportCell(at point: NSPoint) -> (col: UInt32, row: UInt32)? {
        guard bounds.contains(point) else { return nil }
        let cell = gridCell(at: point)
        guard cell.col >= 0, cell.row >= 0, cell.col < Int(cols), cell.row < Int(rows) else { return nil }
        return (UInt32(cell.col), UInt32(cell.row))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = urlTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        urlTrackingArea = area
    }

    private func updateURLHover(at point: NSPoint?) {
        guard let t = tab else { return }
        let cell = selecting ? nil : point.flatMap { viewportCell(at: $0) }
        let hit = mostty_tab_hover_url(t, cell != nil, cell?.col ?? 0, cell?.row ?? 0)
        if hit != hoveringURL { dirty = true }
        if hit { NSCursor.pointingHand.set() }
        else if hoveringURL { NSCursor.arrow.set() }
        hoveringURL = hit
    }

    override func mouseMoved(with event: NSEvent) {
        updateURLHover(at: convert(event.locationInWindow, from: nil))
        dirty = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateURLHover(at: nil) }

    private func openURL(at point: NSPoint) -> Bool {
        guard let t = tab, let cell = viewportCell(at: point) else { return false }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = mostty_tab_url_at(t, cell.col, cell.row, &buf, buf.count)
        guard n > 0, let url = URL(string: String(decoding: buf[0..<n], as: UTF8.self)) else { return false }
        return NSWorkspace.shared.open(url)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let t = tab else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, !event.modifierFlags.contains(.shift), openURL(at: point) {
            selecting = false; selectingWord = false; hasSelection = false
            publishSelection()
            updateURLHover(at: point)
            return
        }
        let cell = cellAt(event)
        selStart = cell; selEnd = cell
        selecting = true; hasSelection = false
        updateURLHover(at: nil)
        selectingWord = event.clickCount == 2
        if selectingWord {
            hasSelection = mostty_tab_select_word(t, UInt32(cell.col), UInt32(cell.row))
            dirty = true
            return
        }
        publishSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard selecting else { return }
        selectingWord = false
        selEnd = cellAt(event)
        hasSelection = selStart != selEnd
        publishSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard selecting else { return }
        selecting = false
        if !selectingWord {
            selEnd = cellAt(event)
            hasSelection = selStart != selEnd
            publishSelection()
        }
        selectingWord = false
        copy(nil)
    }

    /// Hand the selection to the bridge so the highlight is painted with the
    /// configured `selection-background` / `selection-foreground` during
    /// rasterization. Drawing it in an overlay instead could only tint the
    /// finished pixels, which cannot honor a selection foreground color.
    private func publishSelection() {
        guard let t = tab else { return }
        mostty_tab_set_selection(t, hasSelection,
                                 UInt32(selStart.col), UInt32(selStart.row),
                                 UInt32(selEnd.col), UInt32(selEnd.row))
        dirty = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let t = tab else { return }
        scrollAccum += Double(event.scrollingDeltaY)
        // Precise (trackpad) deltas are points and must be divided by the cell
        // height; non-precise (mouse wheel) deltas are already line units.
        let step: Double
        if event.hasPreciseScrollingDeltas {
            let chPts = Double(cellHeightPx) / Double(currentScale())
            step = chPts > 0 ? chPts : 1
        } else {
            step = 1
        }
        let rowsMoved = Int(scrollAccum / step)
        if rowsMoved != 0 {
            scrollAccum -= Double(rowsMoved) * step
            mostty_tab_scroll(t, Int32(-rowsMoved))
            dirty = true
        }
    }

    // MARK: Copy / paste

    @objc func copy(_ sender: Any?) {
        guard hasSelection, let t = tab else { return }
        var probe: UInt8 = 0
        let size = mostty_tab_selection_text(t, &probe, 0)
        guard size > 0 else { return }
        var buf = [UInt8](repeating: 0, count: size)
        let n = mostty_tab_selection_text(t, &buf, buf.count)
        guard n > 0 else { return }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let t = tab, let s = NSPasteboard.general.string(forType: .string) else { return }
        // Terminals expect Enter as CR, including inside bracketed paste.
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\r")
                          .replacingOccurrences(of: "\n", with: "\r")
        var bytes = Array(normalized.utf8)
        if mostty_tab_bracketed_paste(t) {
            // Strip any embedded paste-end marker so clipboard content can't
            // terminate bracketed paste early and inject the trailing bytes as
            // commands (mirrors the Windows PasteEndStripper).
            bytes = KeyInput.stripPasteEnd(bytes)
            bytes = Array("\u{1b}[200~".utf8) + bytes + Array("\u{1b}[201~".utf8)
        }
        writeBytes(bytes)
        scrollToBottomOnInput()
    }

    // MARK: NSTextInputClient

    private func commitMarkedIfNeeded() {
        if !markedText.isEmpty {
            writeString(markedText)
            markedText = ""
            // Tell the IME to drop its pending composition too; otherwise it
            // still believes marking is active and re-commits the same text
            // via insertText, duplicating it.
            inputContext?.discardMarkedText()
            overlay?.needsDisplay = true
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedText = ""
        writeString(s)
        scrollToBottomOnInput()
        overlay?.needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // Composition anchors to the live cursor, which only has a viewport
        // position at the bottom; return there so the overlay isn't drawn over
        // scrollback when the user starts typing while scrolled up.
        scrollToBottomOnInput()
        overlay?.needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        overlay?.needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let t = tab else { return .zero }
        var col: UInt32 = 0, row: UInt32 = 0
        mostty_tab_cursor(t, &col, &row)
        let scale = Double(currentScale())
        let cwPts = Double(cellWidthPx) / scale
        let chPts = Double(cellHeightPx) / scale
        let x = Double(col) * cwPts
        let yFromTop = Double(row) * chPts
        let y = Double(bounds.height) - yFromTop - chPts
        let rect = NSRect(x: x, y: y, width: cwPts, height: chPts)
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    override func doCommand(by selector: Selector) {
        // Swallow default responder commands so unmapped keys don't beep; the
        // terminal encodes special keys itself in keyDown.
    }

    // Overlay accessors
    var overlayMarkedText: String { markedText }
    var overlayCellPoints: (w: Double, h: Double) {
        let scale = Double(currentScale())
        return (Double(cellWidthPx) / scale, Double(cellHeightPx) / scale)
    }
    func overlayCursor() -> (col: Int, row: Int) {
        guard let t = tab else { return (0, 0) }
        var col: UInt32 = 0, row: UInt32 = 0
        mostty_tab_cursor(t, &col, &row)
        return (Int(col), Int(row))
    }
}

/// Transparent layer above the Metal content that draws the IME composition text.
/// The selection highlight is not drawn here: it is applied during rasterization
/// so `selection-foreground` can recolor the glyphs themselves.
final class OverlayView: NSView {
    weak var owner: MosttyTerminalView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass events through

    override func draw(_ dirtyRect: NSRect) {
        guard let owner = owner else { return }
        let (cwp, chp) = owner.overlayCellPoints
        guard cwp > 0, chp > 0 else { return }

        let marked = owner.overlayMarkedText
        if !marked.isEmpty {
            let cursor = owner.overlayCursor()
            let x = Double(cursor.col) * cwp
            let yTop = Double(cursor.row) * chp
            let y = Double(bounds.height) - yTop - chp
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: chp * 0.7, weight: .regular),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor(calibratedWhite: 0.2, alpha: 0.9),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            (marked as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
}
