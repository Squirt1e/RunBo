import AppKit
import SwiftUI
import Core

@main
struct AppEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("RunBo", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: 950, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 860)
        .windowResizability(.contentSize)
        .commands {
            // The app is a single-window app; "New" would create a second workbench.
            CommandGroup(replacing: .newItem) {}
            CardCopyCommands(model: appDelegate.model)
            MenuCommands(model: appDelegate.model)
        }
    }
}

/// App lifecycle: menu bar entry that survives window close, and session cleanup on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItem: NSStatusItem?

    override init() {
        let store: DataStore
        do {
            store = try DataStore()
        } catch {
            // Fall back to a temporary store so the app can still start and report.
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("RunBo-\(UUID().uuidString)", isDirectory: true)
            store = try! DataStore(directory: fallback)
        }
        self.model = AppModel(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = AppIcons.applicationImage {
            NSApp.applicationIconImage = image
        }
        setupStatusItem()
        // SwiftUI restores the previous window size after applying defaultSize.
        // Reset once per launch; reopening a closed window keeps its current size.
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.canBecomeMain })?
                .setContentSize(NSSize(width: 1100, height: 860))
        }
    }

    // MARK: - Closing the window keeps the app and its sessions alive.

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWorkbench()
        return true
    }

    /// Quitting stops every preset and temporary session (normal stop, then force).
    ///
    /// The stop runs *here*, before returning, rather than through `.terminateLater`. That
    /// deferral is a deadlock in this app: while `terminate()` waits for
    /// `reply(toApplicationShouldTerminate:)` it drives a nested run loop that drains
    /// run-loop sources but not main-queue blocks, so a reply posted from the background
    /// thread never runs and the app simply never quits. Waiting the shutdown out on the
    /// main thread costs a few seconds at most (the engine caps it) and always finishes.
    /// `endAllSessions` is idempotent, so the re-entrant call it triggers returns at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.engine.endAllSessions(reason: .appQuit, timeout: 3)
        model.purgeCopiesOnQuit()
        return .terminateNow
    }

    // MARK: - Restart

    /// Restart is a quit with a relaunch attached, so it goes through the very same
    /// termination path — there is no second way to stop sessions. The relaunch is armed
    /// *before* quitting, and waits for this process to disappear, because starting a new
    /// instance while this one is still winding down would have two processes reconciling
    /// the same store.
    private func restart() {
        let alert = NSAlert()
        alert.messageText = "重启 RunBo？"
        alert.informativeText = "全部终端及其子进程会被终止，App 随后自动重新启动。终端不会续接，历史记录按保留规则保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        armRelaunch()
        // Terminating in the same run-loop turn that just closed the modal alert gets
        // swallowed: the app stays up and nothing happens. Letting the loop come back around
        // means terminate() runs from a clean turn, where the delegate is actually reached.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Opens a fresh copy of this App once the current one is gone.
    ///
    /// Two things have to be right, and both were wrong in the first attempt:
    ///
    ///   - The waiter must outlive us: we are about to quit, and a child in our process
    ///     group would be killed with us before it fires. `nohup` does that job — macOS has
    ///     no `setsid` (that is Linux util-linux).
    ///   - It must wait for this pid to actually disappear. A fixed sleep guesses, and when
    ///     the shutdown runs longer than the guess the new instance starts while the old one
    ///     is still alive — two processes on one store, which is what the wait exists to avoid.
    private func armRelaunch() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"
        let target = isAppBundle ? bundleURL.path : Bundle.main.executableURL?.path
        guard let target, !target.isEmpty else { return }

        // `open -n` also works for a bare executable, which is the `swift run` case.
        // Quoting the target keeps paths with spaces intact.
        let quoted = target.replacingOccurrences(of: "'", with: "'\\''")
        let pid = ProcessInfo.processInfo.processIdentifier
        let command = "( i=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt 100 ]; "
            + "do /bin/sleep 0.2; i=$((i+1)); done; "
            + "/usr/bin/open -n '\(quoted)' ) >/dev/null 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/sh", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    @objc private func restartFromMenu() {
        // Running the modal straight from a menu action fights the menu's own event
        // tracking; one main-queue hop lets the menu close first.
        DispatchQueue.main.async { [weak self] in
            self?.restart()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppIcons.menuBarImage
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "RunBo")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "打开 RunBo", action: #selector(openWorkbench), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        // Two rows, because the two menus count different things: temporary terminals are
        // counted by connection (how many are open), preset cards by task (how many are
        // running). One combined number would have to pick one meaning and lie about the other.
        for _ in 0..<2 {
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        // Restart and quit both end every terminal, so they share one separated group at
        // the bottom. This keeps the two status rows at indexes 1 and 2 for menuWillOpen.
        menu.addItem(.separator())
        let clearCopies = NSMenuItem(title: "解除全部一次性分身", action: #selector(clearCopiesFromMenu), keyEquivalent: "")
        clearCopies.target = self
        clearCopies.identifier = NSUserInterfaceItemIdentifier("clear-copies")
        menu.addItem(clearCopies)
        let restart = NSMenuItem(title: "重启 RunBo", action: #selector(restartFromMenu), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "退出 RunBo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openWorkbench() {
        model.openWindowAction?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func clearCopiesFromMenu() {
        openWorkbench()
        model.removeAllCopies()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Each row mirrors its own sidebar menu. Wording follows the interface naming rules
        // (任务 / 终端 / 历史记录 — never 会话).
        if let clear = menu.items.first(where: { $0.identifier?.rawValue == "clear-copies" }) {
            clear.isEnabled = !model.copyKeys.isEmpty && model.removingCopies.isEmpty
        }
        let online = model.onlineCount(for: .temp)
        let executing = model.executingCount(for: .preset)
        menu.item(at: 1)?.title = online > 0 ? "终端在线：\(online)" : "没有在线终端"
        menu.item(at: 2)?.title = executing > 0 ? "快捷指令执行中：\(executing)" : "没有执行中的快捷指令"
    }
}
