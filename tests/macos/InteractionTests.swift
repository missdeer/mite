import AppKit

private final class OriginalDelegate: NSObject, NSWindowDelegate {
    var closes = 0
    var allowsClose = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closes += 1
        return allowsClose
    }
    func windowDidResize(_ notification: Notification) {}
}

@main
struct InteractionTests {
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        let model = AppModel.shared
        defer { model.shutdownAll() }
        for _ in 1..<9 { model.newTab() }
        for index in 0..<9 {
            model.selectTab(at: index)
            expect(model.selectedID == model.tabs[index].id, "numbered selection targets tab \(index + 1)")
        }
        model.cycleTab(1)
        expect(model.selectedID == model.tabs.first?.id, "next tab wraps from last to first")
        model.cycleTab(-1)
        expect(model.selectedID == model.tabs.last?.id, "previous tab wraps from first to last")
        let selected = model.selectedID
        model.selectTab(at: 9)
        model.selectTab(at: -1)
        expect(model.selectedID == selected, "out-of-range shortcuts preserve selection")
        expect(model.launchers.map(\.label) == ["First", "Second"], "launcher menu copies configured choices in order")
        let launcher = model.launchers[1]
        model.newTab(launcher: launcher)
        expect(model.selectedTab?.view.launcher?.command == "echo second" &&
               model.selectedTab?.view.launcher?.directory == "/var", "selected launcher preserves its command and directory")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let active = model.selectedTab!
        active.view.frame = window.contentView!.bounds
        window.contentView = active.view
        expect(active.view.hasActiveSession, "attached terminal has a running session")
        interaction_test_confirmation(true, false)
        model.closeSelected()
        expect(model.selectedID == active.id && interaction_test_alerts() == 1,
               "cancelling a tab close preserves the running session")
        let appDelegate = AppDelegate()
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateCancel,
               "application quit can be cancelled while sessions are active")

        let original = OriginalDelegate()
        window.delegate = original
        model.installWindowDelegate(window)
        let proxy = window.delegate!
        expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))),
               "window delegate preserves original resize callbacks")
        expect(proxy.windowShouldClose?(window) == false && original.closes == 0,
               "window close cancellation does not reach the original delegate")
        interaction_test_confirmation(true, true)
        expect(proxy.windowShouldClose?(window) == false && original.closes == 1 && active.view.hasActiveSession,
               "original delegate veto keeps sessions alive after confirmation")
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateNow,
               "confirmed application quit is allowed")

        interaction_test_confirmation(false, false)
        expect(model.confirmClose([active]) && interaction_test_alerts() == 0,
               "configuration can disable active-session confirmation")
        model.selectTheme("Light")
        expect(model.activeTheme == "Light", "theme menu tracks a successful live switch")
        model.selectTheme("Missing")
        expect(model.activeTheme == "Light", "failed theme load preserves the active theme")

        interaction_test_confirmation(true, true)
        model.close(active.id)
        expect(!model.tabs.contains { $0.id == active.id } && !active.view.hasActiveSession,
               "confirmed close shuts down the selected session")
        interaction_test_confirmation(true, false)
        let unstarted = model.tabs[0]
        model.close(unstarted.id)
        expect(!model.tabs.contains { $0.id == unstarted.id } && interaction_test_alerts() == 0,
               "a tab without an active session closes without confirmation")

        original.allowsClose = true
        expect(proxy.windowShouldClose?(window) == true && model.tabs.isEmpty,
               "accepted window close shuts down every remaining tab")
        model.cycleTab(1)
        expect(model.tabs.isEmpty, "cycling an empty tab list is harmless")

        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/macos-interaction-tests/Config")
        do {
            try Data("confirm-close-surface = false\n".utf8).write(to: configURL)
            interaction_test_config_path(configURL.path)
            var reloads = 0
            let watcher = ConfigWatcher { reloads += 1 }
            expect(watcher != nil, "configuration watcher attaches to the test file")
            try Data().write(to: configURL)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            withExtendedLifetime(watcher) {
                expect(reloads > 0, "emptying configuration reloads defaults and restores close confirmation")
            }
        } catch {
            expect(false, "config reload regression: \(error)")
        }
        print("\(failures) interaction checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
