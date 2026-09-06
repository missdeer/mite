import SwiftUI
import AppKit

final class TabItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = "Terminal"
    let view = MosttyTerminalView(frame: .zero)
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tabs: [TabItem] = []
    @Published var selectedID: UUID?

    var selectedTab: TabItem? { tabs.first { $0.id == selectedID } }

    init() { newTab() }

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

    func makeNSView(context: Context) -> ContainerView { ContainerView() }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.show(model.selectedTab?.view)
    }
}

final class ContainerView: NSView {
    private weak var current: NSView?

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
