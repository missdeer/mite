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

        let sshURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/macos-interaction-tests/ssh-config")
        do {
            let source = "\u{feff}# Hosts\r\nHost alpha beta *.example !blocked ?pattern \"quoted\" # comment\r\n" +
                "  HostName ignored.example\n\thOsT\tgamma\nInclude ignored.conf\n"
            try Data(source.utf8).write(to: sshURL)
            let button = LauncherMenuButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            button.sshConfigURL = sshURL
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = button.menu(for: event)!
            expect(menu.items.map(\.title) == ["[SSH: alpha]", "[SSH: beta]", "[SSH: gamma]"],
                   "SSH-only configuration creates a menu with concrete Host aliases, excluding patterns and HostName")
            let menuWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 60),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            menuWindow.contentView?.addSubview(button)
            menuWindow.orderFront(nil)
            var trackedMenu = false
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { notification in
                guard let openedMenu = notification.object as? NSMenu else { return }
                trackedMenu = openedMenu.items.contains { $0.title == "[SSH: alpha]" }
                DispatchQueue.main.async { openedMenu.cancelTracking() }
            }
            let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 11, y: 11),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: menuWindow.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            button.rightMouseDown(with: click)
            NotificationCenter.default.removeObserver(observer)
            menuWindow.orderOut(nil)
            expect(trackedMenu, "right-clicking the native plus button actually opens the SSH context menu")
            var chosen: TerminalLauncher?
            var opened = 0
            button.openTab = { chosen = $0; opened += 1 }
            menu.performActionForItem(at: 1)
            expect(chosen?.command == "ssh -- 'beta'" && chosen?.directory == "" && opened == 1,
                   "selecting an SSH menu item opens that host through the existing launcher path")
            button.performClick(nil)
            expect(chosen == nil && opened == 2, "left-click still requests the normal default tab")

            button.configuredLaunchers = { model.launchers }
            let mixed = button.menu(for: event)!
            expect(mixed.items.prefix(2).map(\.title) == ["First", "Second"] &&
                   mixed.items[2].isSeparatorItem && mixed.items[3].title == "[SSH: alpha]",
                   "configured launchers precede SSH hosts with a separator")
            try Data("Host updated\n".utf8).write(to: sshURL)
            expect(button.menu(for: event)?.items.last?.title == "[SSH: updated]",
                   "opening the menu reads SSH edits without restarting or reloading Mostty configuration")
            menu.performActionForItem(at: 1)
            expect(chosen?.command == "ssh -- 'beta'", "an open menu keeps its selected command snapshot")
            button.configuredLaunchers = { [] }
            try Data("Host * !excluded\n".utf8).write(to: sshURL)
            expect(button.menu(for: event) == nil, "patterns alone do not produce connectable menu entries")
            button.sshConfigURL = sshURL.appendingPathComponent("missing")
            expect(button.menu(for: event) == nil, "an unreadable SSH config leaves the menu empty")

            let host = "-oProxyCommand=$(id);'literal'"
            let escaped = SSHLaunchers.parse("Host \(host)\n")[0]
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "ssh() { printf '%s\\n' \"$@\"; }; " + escaped.command]
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            expect(process.terminationStatus == 0 && String(data: bytes, encoding: .utf8) == "--\n\(host)\n",
                   "SSH aliases remain one literal shell argument after --, including quotes and command syntax")
        } catch {
            expect(false, "SSH launcher regression: \(error)")
        }

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
        expect(active.view.hasActiveSession && interaction_test_safe_close_default(),
               "tab confirmation puts Cancel first and never makes Close the Return-key default")
        let appDelegate = AppDelegate()
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateCancel,
               "application quit can be cancelled while sessions are active")
        expect(active.view.hasActiveSession && interaction_test_alerts() == 2 && interaction_test_safe_close_default(),
               "quit confirmation uses the same safe default and leaves the running session intact")

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

        let remaining = Array(model.tabs.prefix(2))
        for tab in remaining {
            tab.view.frame = window.contentView!.bounds
            window.contentView = tab.view
        }
        expect(remaining.count == 2 && remaining.allSatisfy { $0.view.hasActiveSession },
               "window-close regression starts with two running sessions")
        original.allowsClose = true
        interaction_test_confirmation(true, false)
        let tabIDs = model.tabs.map(\.id)
        expect(proxy.windowShouldClose?(window) == false && model.tabs.map(\.id) == tabIDs &&
               remaining.allSatisfy { $0.view.hasActiveSession } && interaction_test_alerts() == 1,
               "cancelling window close preserves every tab and running session")
        expect(interaction_test_safe_close_default(),
               "window confirmation never makes Close the Return-key default")
        interaction_test_confirmation(true, true)
        expect(proxy.windowShouldClose?(window) == true && model.tabs.isEmpty &&
               remaining.allSatisfy { !$0.view.hasActiveSession } && interaction_test_alerts() == 1,
               "one accepted window confirmation shuts down every running session")
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateNow && interaction_test_alerts() == 1,
               "quitting after accepted window closure does not ask for a second confirmation")
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
