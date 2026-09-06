import SwiftUI
import AppKit

final class TabItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = "Terminal"
    let view = MosttyTerminalView(frame: .zero)
}

/// Watches the config file and re-applies it without a restart.
///
/// Both the file and its directory are watched, because editors disagree on how
/// they save. An in-place write only touches the file, while a write-temp-then-
/// rename never touches the original inode at all — watching one alone misses
/// half the editors in use.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(onChange: @escaping () -> Void) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = mostty_config_path(&buf, buf.count)
        guard n > 0 else { return nil }
        path = String(decoding: buf[0..<n], as: UTF8.self)
        self.onChange = onChange

        let directory = (path as NSString).deletingLastPathComponent
        // Opening requires the directory to exist; a user who has never saved a
        // config still gets live reload once they do.
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let source = Self.makeSource(directory, mask: [.write, .rename, .delete]) else { return nil }
        directorySource = source
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
        watchFile()
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private static func makeSource(
        _ path: String,
        mask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setCancelHandler { close(descriptor) }
        return source
    }

    // A file source is bound to an inode, so it must be re-established after
    // every event: a rename-based save leaves it watching the replaced file, and
    // the config may not have existed when the watcher started.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        guard let source = Self.makeSource(path, mask: [.write, .extend, .rename, .delete]) else { return }
        fileSource = source
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
    }

    // One save emits several events across both sources, and the editor may not
    // have finished writing when the first arrives; coalesce and let it settle.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.watchFile()
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tabs: [TabItem] = []
    @Published var selectedID: UUID?

    var selectedTab: TabItem? { tabs.first { $0.id == selectedID } }

    /// The live terminal container, so a config reload can refresh the backdrop.
    weak var container: ContainerView?
    private var configWatcher: ConfigWatcher?

    init() {
        newTab()
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
    }

    /// Re-read the config and push it to every live tab plus the window chrome.
    /// `maximize` / `fullscreen` are deliberately not re-applied: they describe
    /// the initial window state, so honoring them here would fight a window the
    /// user has since resized.
    func reloadConfig() {
        guard mostty_config_reload() else { return }
        // Every tab adopts the new font first, then the on-screen tab derives the
        // grid once and broadcasts it. Doing the resize inside the loop would let
        // the active tab publish a grid before the others had the metrics for it,
        // leaving background sessions on the old size until they are next shown.
        for tab in tabs { tab.view.applyConfig() }
        selectedTab?.view.resyncSurface()
        container?.applyBackdrop()
        container?.applyWindowAppearance()
    }

    /// Applies `maximize` / `fullscreen` once the window exists. SwiftUI creates
    /// it after `applicationDidFinishLaunching`, so this runs a turn later. Only
    /// one-shot actions belong here; window *state* such as opacity is owned by
    /// ContainerView, which re-asserts it after SwiftUI builds the scene.
    func applyInitialWindowState() {
        guard let window = terminalWindow() else { return }
        if mostty_config_maximize(), !window.isZoomed { window.zoom(nil) }
        if mostty_config_fullscreen(), !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // The terminal's own window, rather than whichever window AppKit lists
    // first — a font panel or similar auxiliary window must not be restyled.
    private func terminalWindow() -> NSWindow? {
        container?.window ?? NSApp.windows.first { $0.contentView != nil }
    }

    func newTab() {
        let item = TabItem()
        item.view.onTitleChange = { [weak item] title in
            item?.title = title.isEmpty ? "Terminal" : title
        }
        item.view.onExit = { [weak self, weak item] in
            guard let self = self, let item = item else { return }
            self.close(item.id)
        }
        item.view.onSurfaceResize = { [weak self, weak item] pw, ph, scale in
            guard let self = self, let item = item else { return }
            for other in self.tabs where other.id != item.id {
                other.view.applyExternalSurface(pw, ph, scale)
            }
        }
        tabs.append(item)
        selectedID = item.id
    }

    func closeSelected() {
        if let id = selectedID { close(id) }
    }

    func close(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let item = tabs.remove(at: idx)
        item.view.shutdown()
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.last?.id
        }
        if tabs.isEmpty { NSApplication.shared.terminate(nil) }
    }

    func shutdownAll() {
        for t in tabs { t.view.shutdown() }
        tabs.removeAll()
    }
}

/// Hosts the selected tab's persistent terminal view, swapping it on selection
/// change and handing it first-responder status.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView(frame: .zero)
        model.container = view
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.show(model.selectedTab?.view)
    }
}

final class ContainerView: NSView {
    private weak var current: NSView?
    private var backdrop: NSVisualEffectView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyBackdrop()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowAppearance()
    }

    /// `background-opacity < 1` only shows through if the window itself stops
    /// painting an opaque background behind the Metal layer.
    ///
    /// This runs from `viewDidMoveToWindow` rather than at launch because
    /// SwiftUI assigns the scene's own background while building the window,
    /// which silently overwrites an assignment made any earlier.
    func applyWindowAppearance() {
        guard let window = window else { return }
        let translucent = mostty_config_background_opacity() < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor
    }

    /// `background-blur` puts a vibrancy backdrop behind the terminal so
    /// translucent cells composite against the desktop instead of black. It is
    /// meaningless at full opacity, where nothing shows through.
    func applyBackdrop() {
        let wanted = mostty_config_background_blur() && mostty_config_background_opacity() < 1
        if wanted, backdrop == nil {
            let view = NSVisualEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.blendingMode = .behindWindow
            // `.hudWindow` is the one material that stays genuinely see-through
            // in dark mode; the window-background materials render as a nearly
            // opaque panel and would hide the desktop instead of blurring it.
            view.material = .hudWindow
            view.state = .active
            addSubview(view, positioned: .below, relativeTo: nil)
            backdrop = view
        } else if !wanted, let view = backdrop {
            view.removeFromSuperview()
            backdrop = nil
        }
    }

    func show(_ view: NSView?) {
        guard current !== view else { return }
        current?.removeFromSuperview()
        current = view
        if let v = view {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(v)
            }
        }
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        current?.frame = bounds
    }
}

struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab, model: model)
            }
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabChip: View {
    @ObservedObject var tab: TabItem
    @ObservedObject var model: AppModel

    private var isSelected: Bool { model.selectedID == tab.id }

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button(action: { model.close(tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = tab.id }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabBar(model: model)
            TerminalHost(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdownAll() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let possibleUrls: [URL?] = [
            Bundle.main.url(forResource: "mostty", withExtension: "icns"),
            Bundle.main.resourceURL?.appendingPathComponent("mostty.icns"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mostty.icns"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/mostty.icns"),
        ]
        for url in possibleUrls.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = img
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI has not built the Window scene yet at this point.
        DispatchQueue.main.async { AppModel.shared.applyInitialWindowState() }
    }
}

@main
struct MosttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Mostty", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 480, minHeight: 300)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { model.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    NSApp.sendAction(#selector(MosttyTerminalView.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    NSApp.sendAction(#selector(MosttyTerminalView.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
    }
}
