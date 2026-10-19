import AppKit
import Combine
import Foundation
import SwiftUI
import TerminalDeckKit

/// Which page the main content area shows.
enum DeckPage: Equatable {
    case presets
    case temps
    case detail(OwnerKey)
    case history(OwnerKey, String?)
    case editor
    case settings
}

/// Only one title field may own the rename focus, even when both surfaces show the same item.
enum TitleRenameSource {
    case detail
    case workhorseList
}

/// A delete that is waiting for its second tap. The confirmation is drawn on the card
/// itself — a glass sheet over that card — so this replaces the modal alert the two
/// deletions used to raise.
struct PendingDeletion: Equatable {
    let key: OwnerKey
    let title: String
    let running: Bool
}

/// Confirmation dialogs (clear history).
struct DeckAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    var saveAction: (() -> Void)? = nil
    let action: () -> Void
}

/// A card that has been deleted but is still on screen playing its farewell: the card stays
/// in the list until `startedAt + burst.lifetime`, so the grid only closes the gap after the
/// transition is over.
struct CardVanish: Equatable {
    let burst: DeleteBurst
    /// When the transition's clock starts. Unset for the moment between "the user confirmed"
    /// and "the window can paint again" — see `AppModel.startClock(for:)`.
    var startedAt: Date?
}



/// One row of a card list, whichever kind it is. The two menus share the whole block
/// machinery — the only thing that differs between them is which tile gets drawn.
enum PresetCardOrTemp: Identifiable, Equatable {
    case preset(PresetCard)
    case temp(TempTerminal)

    var id: String {
        switch self {
        case .preset(let card): return card.id
        case .temp(let temp): return temp.id
        }
    }

    var tagId: String? {
        switch self {
        case .preset(let card): return card.tagId
        case .temp(let temp): return temp.tagId
        }
    }
}

/// Single source of truth for the SwiftUI layer.
@MainActor
final class AppModel: ObservableObject, SessionEngineDelegate {
    @Published private(set) var cards: [PresetCard] = []
    @Published private(set) var temps: [TempTerminal] = []
    @Published private(set) var removingCopies: Set<OwnerKey> = []
    @Published private(set) var retainingCopies: Set<OwnerKey> = []
    @Published private(set) var newlyCreatedCopyID: String?
    @Published private(set) var copyReflowing = false
    private var copyReflowGeneration = UUID()
    private let copyRunID = UUID().uuidString
    private var removedSessionIDs: Set<String> = []
    /// Most recent runtime per owner, including sessions that already finished, so a
    /// card can keep showing "意外退出" after the shell is gone.
    @Published private(set) var lastRuntime: [OwnerKey: SessionRuntime] = [:]
    /// Latest stored session per owner, used after a relaunch.
    @Published private(set) var storedLastSession: [OwnerKey: SessionRecord] = [:]
    @Published var page: DeckPage = .presets {
        didSet {
            // Only a navigation transition applies the default; manual collapse stays collapsed.
            if page != oldValue {
                fileBrowser.presentationChanged()
                if case .history = page { exitFullscreen() }
                if let key = currentDetailKey { revealWorkhorseItem(key) }
                expandWorkhorseDetail()
                activeArchiveSessionID = archiveSessionID(for: page)
            }
        }
    }
    @Published var defaultShell: String = ShellKind.zsh.rawValue
    /// Terminal font size in points, kept inside `TerminalFontSize`'s range.
    @Published private(set) var terminalFontSize = TerminalFontSize.default
    /// How each menu draws its cards. Kept per menu: the presets list and the temporary
    /// terminal list are handy in different shapes, so one switch must not move the other.
    @Published private(set) var cardModes: [SessionKind: CardDisplayMode] = [:]
    /// 牛马模式：卡片界面之外的第二套工作台。开关落库、默认关闭，进出都不动任何会话。
    @Published private(set) var workhorseMode: WorkhorseMode = .off
    /// 菜单面板宽度占窗口的比例（不是绝对值）：用户拖出来的是「左边占多宽」。
    @Published private(set) var workhorseSidebarRatio = WorkhorseLayout.defaultRatio
    /// 选中项只从当前页面派生：详情/历史选中所属终端，设置、首页、编辑页不保留旧高亮。
    var workhorseSelection: OwnerKey? { currentDetailKey }
    /// 被折叠起来的菜单。默认全部展开，只活在这次运行里（重开即展开），所以不落库。
    /// 放在模型而不是视图里，是因为「保存后要能看见新卡片」需要从外面展开它。
    @Published private(set) var workhorseCollapsedMenus: Set<SessionKind> = []
    /// The tag vocabulary, in block order. Shared by both lists: a tag belongs to the deck,
    /// not to one menu, so renaming it changes the block in both.
    @Published private(set) var tags: [CardTag] = []
    /// Tag blocks the user has folded away. Held by tag id so it survives a rename.
    @Published private(set) var collapsedTagIds: Set<String> = []
    /// The card whose tag picker is open, with the rectangle to hang it from.
    @Published var tagPicker: TagPickerContext?
    /// Card frames in the root view's top-left coordinate space, shared by both layouts.
    /// Native menu actions use these to place the in-app picker beside the correct card.
    private var cardFrames: [String: CGRect] = [:]
    /// The card whose delete is waiting for a second tap; the sheet is drawn on that card.
    @Published private(set) var pendingDeletion: PendingDeletion?
    /// A custom choice remains custom even when its number matches a preset.
    @Published private(set) var terminalFontSizeIsCustom = false
    /// The terminal whose panel is expanded to the whole content area, if any. Holding a key
    /// rather than a flag means leaving the page drops fullscreen without a reset at every
    /// navigation point — see `PanelLayout.isFullscreen`.
    @Published private(set) var fullscreenKey: OwnerKey?
    /// Cards that are on their way out: keyed by owner, so two deletions in a row each get
    /// their own transition and their own cleanup.
    @Published private(set) var vanishing: [OwnerKey: CardVanish] = [:]
    @Published private(set) var historyUsage = HistoryUsage()
    @Published private(set) var feedback: DeckNotice?
    private var queuedErrors: [DeckNotice] = []
    var noticeHovered = false
    // Compatibility for existing integrations; presentation uses the typed feedback above.
    var notice: String? {
        get { feedback?.message }
        set { if let newValue { showNotice(newValue) } else { dismissNotice() } }
    }
    @Published var quickNavigationPresented = false
    /// Ephemeral focus, separate from the selected terminal; never persisted.
    @Published var sidebarFocusedNode: WorkbenchSidebarNode?
    private weak var quickNavigationOrigin: NSResponder?
    private weak var quickNavigationWindow: NSWindow?
    @Published private(set) var historyError: String?
    @Published var alert: DeckAlert?

    // Detail history list
    @Published private(set) var historyEntries: [SessionRecord] = []

    // Inline title rename
    @Published var renamingKey: OwnerKey?
    @Published private(set) var renameSource: TitleRenameSource = .detail
    @Published var renameText: String = ""

    // Card editor draft
    @Published var editorTitle: String = ""
    @Published var editorCommand: String = ""
    @Published var editorShell: String = "default"
    @Published var editorWorkingDirectory: String = ""
    @Published var editorEnvironment: String = ""
    @Published var editorAutoRun: Bool = false
    @Published private(set) var editorValidationAttempt = 0
    @Published private(set) var editorError: String?

    var editorTitleError: String? {
        editorValidationAttempt > 0 && editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "请填写名称。" : nil
    }
    var editorCommandError: String? {
        editorValidationAttempt > 0 && ShellTextNormalizer.normalize(editorCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写启动命令。" : nil
    }
    private(set) var editorEditingCardId: String?
    private(set) var editorSourceTempId: String?

    let sidebar = SidebarPresentation()
    let fileBrowser: FileBrowserCoordinator
    let store: TerminalDeckStore
    let engine: SessionEngine
    private let shimRoot: URL
    private var cleanupTimer: Timer?
    private var noticeTask: Task<Void, Never>?
    private var liveScenes: [String: LiveTerminalScene] = [:]
    private var liveSceneOrder: [String] = []
    private var archiveSceneOrder: [String] = []
    private static let liveSceneLimit = 8
    private static let archiveSceneLimit = 6
    private static let defaultTerminalTitlePrefix = "终端 "
    // The two escaped characters preserve matching of titles saved before this rename.
    private static let previousDefaultTerminalTitlePrefix = "\u{4E34}\u{65F6}终端 "
    /// Output that arrived before a terminal view existed for that session.
    private var outputBacklog: [String: [UInt8]] = [:]
    /// The line currently typed in each live session. Kept in memory only: the spec
    /// forbids persisting raw input, so this can never reach the history store.
    private var typedLine: [String: String] = [:]
    private var lastSubmittedLine: [String: String] = [:]
    /// Titles waiting for their session to actually become ready, so the "已启动"
    /// notice is not shown while the card still says 正在启动.
    private var pendingStartNotice: [String: String] = [:]
    /// Cards that should start again as soon as their current session has stopped:
    /// pressing 启动 on a card whose shell is still alive replaces that session.
    private var pendingRestart: [OwnerKey: PresetCard] = [:]
    private var editorReturnPage: DeckPage = .presets
    private static let outputBacklogLimit = 4 * 1024 * 1024
    private var archiveScenes: [String: ArchiveTerminalScene] = [:]
    /// Replay jobs are retained so evicting a scene also stops its background DB reads.
    private var archiveLoadTasks: [String: Task<Void, Never>] = [:]
    /// Only the archive currently on screen is allowed to consume main-thread parse
    /// time. A paused replay keeps its partial scene and resumes when reopened.
    private var activeArchiveSessionID: String?
    /// Set by the root view so the menu bar item can reopen the window.
    var openWindowAction: (() -> Void)?

    // MARK: - Setup

    init(store: TerminalDeckStore) {
        self.store = store
        self.fileBrowser = FileBrowserCoordinator(store: store)
        self.shimRoot = DeckPaths.shimDirectory(in: store.directory)
        self.engine = SessionEngine(store: store, shimRoot: shimRoot)
        self.engine.delegate = self
        sidebar.businessLock = { [weak self] in self?.sidebarInteractionLocked ?? false }
        sidebar.persist = { [weak self] mode in
            guard let self else { return false }
            do { try self.store.setString(mode.rawValue, forKey: WorkbenchSidebarMode.key); return true }
            catch { self.showError("保存侧栏折叠设置失败：\(error)"); return false }
        }
        loadInitialState()
    }

    private func loadInitialState() {
        // Fail closed: stale disposable cards must never be loaded or auto-run, including after a crash.
        do { try store.purgeStaleCopies(keeping: copyRunID) }
        catch { showError("无法清理上次的一次性分身：\(error)"); return }
        do {
            defaultShell = try store.string(forKey: "default_shell") ?? ShellLocator.defaultShell()
            for kind in SessionKind.allCases {
                cardModes[kind] = CardDisplay.mode(
                    fromStored: try store.string(forKey: CardDisplay.key(for: kind))
                )
            }
            workhorseMode = WorkhorseMode.stored(try store.string(forKey: WorkhorseMode.key))
            sidebar.restore(WorkbenchSidebarMode.stored(try store.string(forKey: WorkbenchSidebarMode.key)))
            // Layout compatibility marker; both layouts now share the same DeckTheme material.
            DeckTheme.palette = workhorseMode.isOn ? .workhorse : .standard
            workhorseSidebarRatio = WorkhorseLayout.storedRatio(
                try store.string(forKey: WorkhorseLayout.sidebarRatioKey)
            )
            terminalFontSize = TerminalFontSize.clamp(
                Double(try store.string(forKey: Self.terminalFontSizeKey) ?? "")
            )
            let savedMode = try store.string(forKey: Self.terminalFontSizeModeKey)
            terminalFontSizeIsCustom = savedMode == "custom"
                || TerminalFontSize.preset(for: terminalFontSize) == nil
            cards = try store.cards()
            temps = try store.temps()
            tags = try store.tags()
            collapsedTagIds = Self.decodeCollapsedTags(try store.string(forKey: Self.collapsedTagsKey))
            for index in temps.indices {
                guard let title = Self.updatedDefaultTerminalTitle(temps[index].title) else { continue }
                temps[index].title = title
                try store.save(temps[index])
            }
            for card in cards {
                if let session = try store.latestSession(kind: .preset, ownerId: card.id) {
                    storedLastSession[OwnerKey(kind: .preset, ownerId: card.id)] = session
                }
            }
            for temp in temps {
                if let session = try store.latestSession(kind: .temp, ownerId: temp.id) {
                    storedLastSession[OwnerKey(kind: .temp, ownerId: temp.id)] = session
                }
            }
        } catch {
            showError("无法读取本地数据：\(error)")
        }

        // Sessions left open by a crash are closed out; the app never resumes shells.
        engine.reconcileLeftovers()
        sweepExpiredTemps()
        refreshUsage()
        startCleanupTimer()
        pruneLegacyHistory()
        startAutoRunCards()
    }

    /// Only cards with "启动 App 时自动运行" are started; temporary terminals never are.
    private func startAutoRunCards() {
        for card in cards where card.autoRun && card.copy?.runID == nil {
            start(card: card, announce: false)
        }
    }

    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepExpiredTemps()
                self?.refreshUsage()
            }
        }
    }

    // MARK: - Derived state

    func isRunning(_ key: OwnerKey) -> Bool {
        engine.runtime(for: key) != nil
    }

    func executingCount(for kind: SessionKind) -> Int { engine.executingCount(for: kind) }

    /// Temporary terminals that are online and ready for input, whatever they are running.
    /// This is the number the 终端 menu shows: "how many terminals do I still have open".
    func onlineCount(for kind: SessionKind) -> Int { engine.onlineCount(for: kind) }

    /// Pure projection from the published state; rendering home never queries the database
    /// or samples raw terminal input. Delegate updates keep it live with the sidebar.
    var workhorseHome: WorkhorseHomeSnapshot {
        WorkhorseHomeSnapshot(cards: cards, temps: temps, runtimes: Array(lastRuntime.values),
                              storedSessions: storedLastSession)
    }

    func listPage(for key: OwnerKey) -> DeckPage {
        key.kind == .preset ? .presets : .temps
    }

    var selectedKind: SessionKind? {
        switch page {
        case .presets: return .preset
        case .temps: return .temp
        case .detail(let key), .history(let key, _): return key.kind
        case .editor:
            if case .detail(let key) = editorReturnPage { return key.kind }
            return .preset
        case .settings: return nil
        }
    }

    func openHistory(for key: OwnerKey) {
        loadHistoryEntries(for: key)
        page = .history(key, nil)
    }

    func showHistoryRecord(_ sessionId: String, for key: OwnerKey) {
        page = .history(key, sessionId)
    }

    func backFromHistory(for key: OwnerKey, sessionId: String?) {
        page = sessionId == nil ? .detail(key) : .history(key, nil)
    }

    func liveRuntime(_ key: OwnerKey) -> SessionRuntime? {
        engine.runtime(for: key)
    }

    func presentation(for key: OwnerKey) -> SessionStatusPresentation {
        if let runtime = engine.runtime(for: key) {
            return runtime.presentation
        }
        if let runtime = lastRuntime[key] {
            if key.kind == .temp, runtime.status == .stopped, temp(for: key.ownerId)?.launchConfiguration != nil {
                return SessionStatusPresentation(label: "未运行", tone: .idle)
            }
            return runtime.presentation
        }
        if let session = storedLastSession[key] {
            if session.launchFailed { return SessionStatusPresentation(label: "启动失败", tone: .failed) }
            if session.unexpectedExit { return SessionStatusPresentation(label: "意外退出", tone: .failed) }
        }
        return SessionStatusPresentation(label: "未运行", tone: .idle)
    }

    /// Runtime backing the detail page, including the last finished runtime.
    func detailRuntime(_ key: OwnerKey) -> SessionRuntime? {
        engine.runtime(for: key) ?? lastRuntime[key]
    }

    func sessionCount(for key: OwnerKey) -> Int {
        (try? store.sessions(kind: key.kind, ownerId: key.ownerId).filter(\.isFinished).count) ?? 0
    }

    func historyCount(for key: OwnerKey) -> Int {
        min(sessionCount(for: key), RetentionPolicy.sessionHistoryLimit)
    }

    func fileBrowserRoot(for key: OwnerKey) -> URL {
        FileBrowserPaths.root(
            sessionDirectory: detailRuntime(key)?.workingDirectory ?? storedLastSession[key]?.workingDirectory,
            configuredDirectory: key.kind == .preset ? card(for: key.ownerId)?.workingDirectory
                : temp(for: key.ownerId)?.launchConfiguration?.workingDirectory
        )
    }

    func card(for id: String) -> PresetCard? { cards.first { $0.id == id } }
    func temp(for id: String) -> TempTerminal? { temps.first { $0.id == id } }

    // MARK: - Disposable card copies

    func copyIdentity(_ key: OwnerKey) -> CardCopy? {
        key.kind == .preset ? card(for: key.ownerId)?.copy : temp(for: key.ownerId)?.copy
    }
    func isDisposableCopy(_ key: OwnerKey) -> Bool { copyIdentity(key)?.runID != nil }
    func copyIsBusy(_ key: OwnerKey) -> Bool { removingCopies.contains(key) || retainingCopies.contains(key) }
    var copyKeys: Set<OwnerKey> {
        Set(cards.filter { $0.copy?.runID != nil }.map { OwnerKey(kind: .preset, ownerId: $0.id) }
            + temps.filter { $0.copy?.runID != nil }.map { OwnerKey(kind: .temp, ownerId: $0.id) })
    }
    var copyOnlineCount: Int { copyKeys.filter { isRunning($0) }.count }
    func canCreateCopy(_ key: OwnerKey) -> Bool {
        key.kind == .preset && removingCopies.isEmpty && !engine.isQuitting
    }

    func createCopy(_ key: OwnerKey) {
        guard canCreateCopy(key), !copyIsBusy(key), vanishing[key] == nil else { return }
        do {
            let newKey = try store.createCopy(of: key, runID: copyRunID, defaultShell: defaultShell)
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) {
                refreshCardsAfterTagChange()
            }
            expandWorkhorseMenu(key.kind)
            let bucket = tagID(for: newKey) ?? Self.untaggedBucketID
            if collapsedTagIds.remove(bucket) != nil { persistCollapsedTags() }
            newlyCreatedCopyID = newKey.ownerId
            showNotice("已创建一次性分身，尚未启动。")
        } catch { showError("创建分身失败：\(error)", retry: { [weak self] in self?.createCopy(key) }) }
    }

    func retainCopy(_ key: OwnerKey) {
        guard isDisposableCopy(key), !copyIsBusy(key), !engine.isQuitting else { return }
        if page == .editor, editorEditingCardId == key.ownerId, editorHasUnsavedChanges {
            protectCopyDraft { [weak self] in self?.retainCopy(key) }
            return
        }
        retainingCopies.insert(key)
        defer { retainingCopies.remove(key) }
        do {
            try store.retainCopy(key)
            // The durable transaction is the commit point. No second read is needed to
            // update this exact card's identity, and its live terminal/view stays mounted.
            if key.kind == .preset, let index = cards.firstIndex(where: { $0.id == key.ownerId }) {
                cards[index].copy = nil
            } else if key.kind == .temp, let index = temps.firstIndex(where: { $0.id == key.ownerId }) {
                temps[index].copy = nil
            }
            protectCopyReflow()
            showNotice("已保留为普通卡片，下次打开仍在。")
        } catch { showError("保留失败，仍为一次性分身：\(error)", retry: { [weak self] in self?.retainCopy(key) }) }
    }

    func removeCopy(_ key: OwnerKey) { requestRemoveCopies([key]) }
    func removeAllCopies() { requestRemoveCopies(copyKeys) }

    private func protectCopyDraft(_ proceed: @escaping () -> Void) {
        alert = DeckAlert(title: "放弃未保存的修改？", message: "操作针对已保存的分身配置，尚未保存的修改会丢失。",
                          confirmTitle: "放弃修改", destructive: true) { [weak self] in
            self?.cancelEditor()
            proceed()
        }
    }

    private func requestRemoveCopies(_ keys: Set<OwnerKey>, confirmedSessions: [OwnerKey: String] = [:]) {
        guard removingCopies.isEmpty, !engine.isQuitting else { return }
        let targets = keys.intersection(copyKeys).subtracting(retainingCopies)
        guard !targets.isEmpty else { return }
        if page == .editor, let id = editorEditingCardId,
           targets.contains(OwnerKey(kind: .preset, ownerId: id)), editorHasUnsavedChanges {
            protectCopyDraft { [weak self] in self?.requestRemoveCopies(targets) }
            return
        }
        // Confirmation covers exact sessions: a restarted PTY needs a fresh decision.
        let live = Dictionary(uniqueKeysWithValues: targets.compactMap { key -> (OwnerKey, String)? in
            guard let runtime = liveRuntime(key), runtime.status.isAlive else { return nil }
            return (key, runtime.sessionId)
        })
        if live.contains(where: { confirmedSessions[$0.key] != $0.value }) {
            let names = live.keys.sorted { $0.ownerId < $1.ownerId }.map { key in
                key.kind == .preset ? (card(for: key.ownerId)?.title ?? "分身") : (temp(for: key.ownerId)?.title ?? "分身")
            }.joined(separator: "、")
            alert = DeckAlert(title: "解除在线分身？",
                              message: "将结束 \(live.count) 个仍存活的分身终端（\(names)），并清理目标分身及其 App 内历史。此操作不能恢复终端进程；原卡与已保留卡片不受影响。",
                              confirmTitle: "结束终端并解除", destructive: true) { [weak self] in
                self?.requestRemoveCopies(targets, confirmedSessions: live)
            }
            return
        }
        removingCopies = targets
        cancelDeletion()
        closeTagPicker()
        for key in targets { pendingRestart[key] = nil }
        // 解除和普通删除用同一份告别：先记下粒子，卡片留在列表里播完再收。
        // 解除是异步的（要等终端围栏），所以这里记下时长，落库后再等它演完。
        var bursts: [OwnerKey: Double] = [:]
        for key in targets {
            beginVanish(key)
            bursts[key] = vanishing[key]?.burst.lifetime ?? 0
        }
        let engine = self.engine
        Task { [weak self] in
            let ready = await Task.detached { engine.prepareForRemoval(targets) }.value
            guard let self else { return }
            var removedKeys: Set<OwnerKey> = []
            for key in targets {
                guard ready.contains(key) else { continue }
                let sessionIDs = ((try? self.store.sessions(kind: key.kind, ownerId: key.ownerId)) ?? []).map(\.id)
                    + engine.allRuntimes.filter { $0.key == key }.map(\.sessionId)
                do {
                    try self.store.removeCopy(key)
                    self.removedSessionIDs.formUnion(sessionIDs)
                    self.discardCachedSessions(Set(sessionIDs))
                    self.historyEntries.removeAll { $0.kind == key.kind && $0.ownerId == key.ownerId }
                    self.cardFrames[key.ownerId] = nil
                    if self.newlyCreatedCopyID == key.ownerId { self.newlyCreatedCopyID = nil }
                    engine.forgetRemovedOwner(key)
                    self.lastRuntime[key] = nil; self.storedLastSession[key] = nil
                    if self.renamingKey == key { self.cancelRename() }
                    if self.currentDetailKey == key || (self.page == .editor && self.editorEditingCardId == key.ownerId) {
                        self.editorEditingCardId = nil
                        self.exitFullscreen()
                        self.historyEntries = []
                        self.page = self.workhorseMode.isOn ? .presets : self.listPage(for: key)
                    }
                    removedKeys.insert(key)
                } catch { /* Keep the failed card visible for retry; never report it as removed. */ }
            }
            // 数据已经删掉了，界面再等粒子演完——和 `confirmDeletion` → `beginVanish` 一样，
            // 落库不延后，只有这声「再见」延后。
            let longest = bursts.filter { removedKeys.contains($0.key) }.values.max() ?? 0
            await waitForBurst(bursts: bursts, removedKeys: removedKeys, longest: longest)
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)) {
                self.cards.removeAll { removedKeys.contains(OwnerKey(kind: .preset, ownerId: $0.id)) }
                self.temps.removeAll { removedKeys.contains(OwnerKey(kind: .temp, ownerId: $0.id)) }
                for index in self.cards.indices {
                    if let anchor = self.cards[index].copy?.anchorID,
                       removedKeys.contains(OwnerKey(kind: .preset, ownerId: anchor)) { self.cards[index].copy?.anchorID = nil }
                }
                for index in self.temps.indices {
                    if let anchor = self.temps[index].copy?.anchorID,
                       removedKeys.contains(OwnerKey(kind: .temp, ownerId: anchor)) { self.temps[index].copy?.anchorID = nil }
                }
            }
            self.fileBrowser.remove(removedKeys)
            for key in removedKeys { self.vanishing[key] = nil }
            if !removedKeys.isEmpty { self.protectCopyReflow() }
            self.removingCopies = []
            self.refreshUsage()
            let removed = removedKeys.count
            let failed = targets.count-removed
            if failed == 0 {
                self.showNotice("已解除 \(removed) 个分身，原卡与已保留卡片未变。")
            } else {
                let remaining = targets.subtracting(removedKeys)
                self.showError("已解除 \(removed) 个，\(failed) 个未解除，请重试。", retry: { [weak self] in
                    self?.requestRemoveCopies(remaining)
                })
            }
        }
    }

    /// Waits until a removed card's burst has actually played, so the row is still mounted while
    /// the particles fly. The clock starts on the next main-queue turn, so this reads that record
    /// back instead of assuming an offset; the deadline keeps a lost record from stalling removal.
    ///
    /// `Task.sleep` rather than a spin: this is the main actor, and a blocked runloop would never
    /// give the particle field the frame it is waiting for.
    private func waitForBurst(bursts: [OwnerKey: Double], removedKeys: Set<OwnerKey>, longest: Double) async {
        guard longest > 0 else { return }
        for key in removedKeys {
            guard let lifetime = bursts[key], lifetime > 0 else { continue }
            let deadline = Date().addingTimeInterval(lifetime + 0.4)
            while Date() < deadline {
                guard let record = vanishing[key] else { break }
                if let started = record.startedAt, Date().timeIntervalSince(started) >= lifetime { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Briefly reject positional clicks while a removed footer/row gives way to a neighbour.
    /// Backend operations remain keyed by ID; this only protects the moving UI's hit targets.
    private func protectCopyReflow() {
        copyReflowing = true
        let generation = UUID()
        copyReflowGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.copyReflowGeneration == generation else { return }
            self.copyReflowing = false
        }
    }

    /// After App shutdown fenced all PTYs. Crash recovery also performs this before load.
    func purgeCopiesOnQuit() {
        let keys = copyKeys
        guard !keys.isEmpty else { return }
        let ready = engine.prepareForRemoval(keys, timeout: 0)
        for key in ready { try? store.removeCopy(key) }
    }

    // MARK: - Terminal scenes

    func liveScene(sessionId: String) -> LiveTerminalScene {
        if let scene = liveScenes[sessionId] {
            markSceneUsed(sessionId, in: &liveSceneOrder)
            return scene
        }
        let directory = engine.runtime(sessionId: sessionId)?.workingDirectory
            ?? (try? store.session(id: sessionId))?.workingDirectory
        let scene = LiveTerminalScene(sessionId: sessionId, workingDirectory: directory)
        scene.links.currentDirectory = { [weak self] in
            self?.engine.currentWorkingDirectory(sessionId: sessionId).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        scene.links.onFailure = { [weak self] message in self?.showError(message) }
        scene.onInput = { [weak self] bytes in
            self?.noteTypedBytes(bytes, sessionId: sessionId)
            self?.engine.send(bytes: bytes, to: sessionId)
        }
        scene.onResize = { [weak self] cols, rows in
            self?.engine.resize(sessionId: sessionId, cols: cols, rows: rows)
        }
        liveScenes[sessionId] = scene
        markSceneUsed(sessionId, in: &liveSceneOrder)
        while liveSceneOrder.count > Self.liveSceneLimit, let oldest = liveSceneOrder.first {
            liveSceneOrder.removeFirst()
            // The mounted NSView keeps its own strong reference, so evicting the cache
            // entry never pulls a view out from under SwiftUI.
            if oldest != sessionId { liveScenes[oldest] = nil }
        }
        // Replay whatever the session produced before this view existed.
        if let backlog = outputBacklog.removeValue(forKey: sessionId) {
            scene.feed(backlog)
        }
        return scene
    }

    /// Tracks the command line the user is typing so "另存为卡片" can prefill it.
    /// Nothing here is written to disk.
    private func noteTypedBytes(_ bytes: [UInt8], sessionId: String) {
        var line = typedLine[sessionId] ?? ""
        for byte in bytes {
            switch byte {
            case 0x0D, 0x0A:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lastSubmittedLine[sessionId] = trimmed }
                line = ""
            case 0x7F, 0x08:
                if !line.isEmpty { line.removeLast() }
            case 0x03, 0x15: // Ctrl-C / Ctrl-U abandon the line
                line = ""
            default:
                if byte >= 0x20, byte < 0x7F { line.append(Character(UnicodeScalar(byte))) }
            }
        }
        typedLine[sessionId] = line
    }

    /// Last command line typed in a session, if the user has not left it since launch.
    func lastTypedCommand(sessionId: String) -> String? {
        lastSubmittedLine[sessionId]
    }

    func archiveScene(sessionId: String) -> ArchiveTerminalScene {
        if let scene = archiveScenes[sessionId] {
            markSceneUsed(sessionId, in: &archiveSceneOrder)
            activeArchiveSessionID = sessionId
            return scene
        }
        let directory = (try? store.session(id: sessionId))?.workingDirectory
        let scene = ArchiveTerminalScene(sessionId: sessionId, workingDirectory: directory)
        scene.links.onFailure = { [weak self] message in self?.showError(message) }
        archiveScenes[sessionId] = scene
        markSceneUsed(sessionId, in: &archiveSceneOrder)
        activeArchiveSessionID = sessionId
        while archiveSceneOrder.count > Self.archiveSceneLimit, let oldest = archiveSceneOrder.first {
            archiveSceneOrder.removeFirst()
            guard oldest != sessionId else { continue }
            archiveLoadTasks.removeValue(forKey: oldest)?.cancel()
            archiveScenes[oldest] = nil
        }
        startArchiveReplay(sessionId: sessionId, scene: scene)
        return scene
    }

    /// Reads history in bounded pages and feeds it in small main-thread slices. A
    /// 10 MB archive used to block the run loop for over ten seconds in one loop; the
    /// App now stays responsive and shows a small loading badge while it reconstructs.
    private func startArchiveReplay(sessionId: String, scene: ArchiveTerminalScene) {
        guard archiveLoadTasks[sessionId] == nil else { return }
        let store = self.store
        archiveLoadTasks[sessionId] = Task { @MainActor [weak self, weak scene] in
            guard let scene, scene.beginReplay() else {
                self?.archiveLoadTasks[sessionId] = nil
                return
            }
            let pageSize = 64
            var cursor: Int64 = -1
            while !Task.isCancelled {
                // Wait until this archive is the one on screen. Multiple cards used to
                // replay at once after fast switching, which made navigation stutter.
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.activeArchiveSessionID == sessionId { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if Task.isCancelled { break }
                let after = cursor
                let page = await Task.detached(priority: .userInitiated) {
                    (try? store.events(sessionId: sessionId, afterSequence: after, limit: pageSize)) ?? []
                }.value
                if Task.isCancelled { break }
                if page.isEmpty { break }
                await scene.appendReplay(page) { [weak self] in
                    self?.activeArchiveSessionID == sessionId
                }
                if Task.isCancelled { break }
                cursor = page.last?.sequence ?? cursor
                if page.count < pageSize { break }
            }
            if Task.isCancelled {
                scene.cancelReplay()
            } else {
                await scene.finishReplay()
            }
            self?.archiveLoadTasks[sessionId] = nil
        }
    }

    /// The archive a page will actually display. Live details use their live scene;
    /// history lists and non-terminal pages have no archive to keep active.
    private func archiveSessionID(for page: DeckPage) -> String? {
        switch page {
        case .detail(let key):
            guard liveRuntime(key)?.status.isAlive != true else { return nil }
            return detailRuntime(key)?.sessionId ?? storedLastSession[key]?.id
        case .history(let key, let sessionId):
            guard let sessionId else { return nil }
            return liveRuntime(key)?.sessionId == sessionId ? nil : sessionId
        default:
            return nil
        }
    }

    private func markSceneUsed(_ sessionId: String, in order: inout [String]) {
        if let index = order.firstIndex(of: sessionId) { order.remove(at: index) }
        order.append(sessionId)
    }

    /// Drops every in-memory record of sessions that no longer exist. The database has
    /// already deleted their rows; leaving scene views and input buffers behind would
    /// keep whole terminals alive until the LRU happened to evict them.
    private func discardCachedSessions(_ sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        if let active = activeArchiveSessionID, sessionIDs.contains(active) {
            activeArchiveSessionID = nil
        }
        for id in sessionIDs {
            archiveLoadTasks.removeValue(forKey: id)?.cancel()
            liveScenes[id] = nil
            archiveScenes[id] = nil
            outputBacklog[id] = nil
            typedLine[id] = nil
            lastSubmittedLine[id] = nil
            pendingStartNotice[id] = nil
        }
        liveSceneOrder.removeAll { sessionIDs.contains($0) }
        archiveSceneOrder.removeAll { sessionIDs.contains($0) }
    }

    /// Retention deletes old session rows in the background; their cached archive
    /// scenes must go with them. Without this, a long-lived App could keep up to
    /// `archiveSceneLimit` replays of sessions that no longer exist in SQLite.
    private func pruneOrphanedArchiveScenes() {
        guard !archiveScenes.isEmpty else { return }
        for id in Array(archiveScenes.keys) {
            let exists: Bool
            do { exists = try store.session(id: id) != nil } catch { continue }
            guard !exists else { continue }
            archiveLoadTasks.removeValue(forKey: id)?.cancel()
            if activeArchiveSessionID == id { activeArchiveSessionID = nil }
            archiveScenes[id] = nil
            archiveSceneOrder.removeAll { $0 == id }
        }
    }

    /// Applies the two-record policy to histories written by older builds. Runs off the
    /// main thread: a first upgrade may have to delete a lot of session_events rows.
    private func pruneLegacyHistory() {
        let store = self.store
        Task { @MainActor [weak self] in
            let removed = await Task.detached(priority: .utility) {
                (try? store.trimAllHistory()) ?? []
            }.value
            guard let self, !removed.isEmpty else { return }
            let gone = Set(removed)
            self.historyEntries.removeAll { gone.contains($0.id) }
            for id in gone {
                self.archiveLoadTasks.removeValue(forKey: id)?.cancel()
                if self.activeArchiveSessionID == id { self.activeArchiveSessionID = nil }
                self.archiveScenes[id] = nil
            }
            self.archiveSceneOrder.removeAll { gone.contains($0) }
            self.refreshStoredSessions()
            self.refreshUsage()
            if case .history(let key, _) = self.page { self.loadHistoryEntries(for: key) }
        }
    }

    // MARK: - Session actions

    /// Starts a card's session. A card owns one session at a time, so if one is still
    /// alive (for example after its command failed, where the shell stays usable) the
    /// current session is ended first and the new one starts as soon as it exited.
    func startCard(_ card: PresetCard, announce: Bool = true) {
        let key = OwnerKey(kind: .preset, ownerId: card.id)
        guard !copyIsBusy(key), self.card(for: card.id) != nil, !engine.isQuitting else { return }
        if let runtime = engine.runtime(for: key) {
            pendingRestart[key] = card
            if runtime.needsForceTermination {
                engine.forceStop(sessionId: runtime.sessionId)
            } else {
                engine.stop(sessionId: runtime.sessionId)
            }
            return
        }
        start(card: card, announce: announce)
    }

    /// Creates the terminal view for a session up front so no output is lost while
    /// the user is still on a list page.
    private func prepareScene(for runtime: SessionRuntime) {
        _ = liveScene(sessionId: runtime.sessionId)
    }

    private func start(card: PresetCard, announce: Bool) {
        let key = OwnerKey(kind: .preset, ownerId: card.id)
        guard engine.runtime(for: key) == nil, !copyIsBusy(key), !engine.isQuitting else { return }
        let shell = card.shellOverride ?? defaultShell
        do {
            let runtime = try engine.start(
                kind: .preset,
                ownerId: card.id,
                title: card.title,
                shell: shell,
                command: card.command,
                workingDirectory: card.workingDirectory,
                environment: card.environment
            )
            lastRuntime[key] = runtime
            prepareScene(for: runtime)
            // Starting this run may have trimmed an older session row on disk.
            pruneOrphanedArchiveScenes()
            if announce { pendingStartNotice[runtime.sessionId] = card.title }
        } catch {
            showError("“\(card.title)”启动失败：\(describe(error))", retry: { [weak self] in
                guard let self, let current = self.card(for: card.id), !self.isRunning(key) else { return }
                self.startCard(current)
            })
            refreshStoredStatus(for: key)
        }
    }

    /// Clicking any card opens its terminal detail. Starting a task is an explicit
    /// action on the card (启动), so a click never launches or misses silently.
    func openDetail(_ key: OwnerKey) {
        page = .detail(key)
    }

    func createTempTerminal() {
        leaveEditorIfNeeded { [weak self] in self?.prepareTempTerminal() }
    }

    private func prepareTempTerminal() {
        let nextIndex = (temps.compactMap { temp -> Int? in
            guard temp.title.hasPrefix(Self.defaultTerminalTitlePrefix) else { return nil }
            return Int(temp.title.dropFirst(Self.defaultTerminalTitlePrefix.count))
        }.max() ?? 0) + 1
        let temp = TempTerminal(title: "\(Self.defaultTerminalTitlePrefix)\(nextIndex)")
        do {
            try store.save(temp)
            temps.append(temp)
        } catch {
            showError("无法保存终端：\(error)", retry: { [weak self] in self?.createTempTerminal() })
            return
        }
        startTemp(temp, announce: true, openDetail: true)
    }

    private static func updatedDefaultTerminalTitle(_ title: String) -> String? {
        guard title.hasPrefix(previousDefaultTerminalTitlePrefix),
              let number = Int(title.dropFirst(previousDefaultTerminalTitlePrefix.count)),
              number > 0,
              title == "\(previousDefaultTerminalTitlePrefix)\(number)" else { return nil }
        return "\(defaultTerminalTitlePrefix)\(number)"
    }

    /// Starts a temporary terminal. `openDetail` is only used by "新建终端", which
    /// opens the new terminal's detail; starting from a card stays on the list.
    func startTemp(_ temp: TempTerminal, announce: Bool = false, openDetail: Bool = false) {
        let key = OwnerKey(kind: .temp, ownerId: temp.id)
        guard !copyIsBusy(key), self.temp(for: temp.id) != nil, !engine.isQuitting else { return }
        guard engine.runtime(for: key) == nil else {
            if openDetail {
                page = .detail(key)
            }
            return
        }
        do {
            let runtime = try engine.start(
                kind: .temp,
                ownerId: temp.id,
                title: temp.title,
                shell: temp.launchConfiguration?.shell ?? defaultShell,
                command: nil,
                workingDirectory: temp.launchConfiguration?.workingDirectory,
                environment: temp.launchConfiguration?.environment ?? [:]
            )
            lastRuntime[key] = runtime
            prepareScene(for: runtime)
            pruneOrphanedArchiveScenes()
            try? store.touchTemp(id: temp.id)
            if openDetail {
                page = .detail(key)
            }
            if announce { showNotice("新终端已创建。") }
        } catch {
            showError("终端启动失败：\(describe(error))", retry: { [weak self] in
                guard let self, let current = self.temp(for: temp.id), !self.isRunning(key) else { return }
                self.startTemp(current)
            })
        }
    }

    func stop(_ key: OwnerKey) {
        guard let runtime = engine.runtime(for: key) else { return }
        engine.stop(sessionId: runtime.sessionId)
    }

    func forceStop(_ key: OwnerKey) {
        guard let runtime = engine.runtime(for: key) else { return }
        engine.forceStop(sessionId: runtime.sessionId)
    }

    func restart(_ key: OwnerKey) {
        switch key.kind {
        case .preset:
            if let card = card(for: key.ownerId) { startCard(card) }
        case .temp:
            if let temp = temp(for: key.ownerId) { startTemp(temp) }
        }
    }

    // MARK: - Cards and temporary terminals

    var editorPageTitle: String {
        if editorEditingCardId != nil { return "编辑快捷指令" }
        if editorSourceTempId != nil { return "另存为快捷指令" }
        return "添加快捷指令"
    }

    func beginNewCard() {
        leaveEditorIfNeeded { [weak self] in self?.prepareNewCard() }
    }

    private func prepareNewCard() {
        resetEditorValidation()
        // 牛马模式的列表常驻，所以「取消」必须回到进来之前看的那一项，而不是某个列表页。
        editorReturnPage = workhorseMode.isOn
            ? (workhorseSelection.map { .detail($0) } ?? .presets)
            : .presets
        editorEditingCardId = nil
        editorSourceTempId = nil
        editorTitle = ""
        editorCommand = ""
        editorShell = "default"
        editorWorkingDirectory = ""
        editorEnvironment = ""
        editorAutoRun = false
        page = .editor
    }

    func beginEditCard(_ card: PresetCard) {
        if page == .editor, editorEditingCardId == card.id { return }
        leaveEditorIfNeeded { [weak self] in
            guard let self, let current = self.card(for: card.id) else { return }
            self.prepareEditCard(current)
        }
    }

    private func prepareEditCard(_ card: PresetCard) {
        resetEditorValidation()
        guard !copyIsBusy(OwnerKey(kind: .preset, ownerId: card.id)) else { return }
        let key = OwnerKey(kind: .preset, ownerId: card.id)
        editorReturnPage = workhorseMode.isOn ? .detail(key) : .presets
        editorEditingCardId = card.id
        editorSourceTempId = nil
        editorTitle = card.title
        // Cards saved before smart substitutions were disabled may hold typographic
        // punctuation; show the shell-usable form so saving repairs the card.
        editorCommand = ShellTextNormalizer.normalize(card.command)
        editorShell = card.shellOverride ?? "default"
        editorWorkingDirectory = card.workingDirectory ?? ""
        editorEnvironment = ShellTextNormalizer.normalize(EnvironmentParser.render(card.environment))
        editorAutoRun = card.autoRun
        page = .editor
    }

    /// Saves the command tried in a temporary terminal as a preset card.
    func beginSaveTempAsCard(_ temp: TempTerminal) {
        leaveEditorIfNeeded { [weak self] in self?.prepareSaveTempAsCard(temp) }
    }

    private func prepareSaveTempAsCard(_ temp: TempTerminal) {
        resetEditorValidation()
        editorReturnPage = .detail(OwnerKey(kind: .temp, ownerId: temp.id))
        editorEditingCardId = nil
        editorSourceTempId = temp.id
        editorTitle = temp.title
        // Prefill from the line the user just tried (memory only) or, when the temp
        // terminal is not live any more, from the recorded preset command if any.
        let liveSessionId = liveRuntime(OwnerKey(kind: .temp, ownerId: temp.id))?.sessionId
        let remembered = liveSessionId.flatMap { lastTypedCommand(sessionId: $0) }
        let stored = try? store.latestSession(kind: .temp, ownerId: temp.id)
        editorCommand = ShellTextNormalizer.normalize(remembered ?? stored?.lastCommandText ?? "")
        editorShell = "default"
        editorWorkingDirectory = ""
        editorEnvironment = ""
        editorAutoRun = false
        page = .editor
    }

    /// UI exits must ask first; cancelEditor is the confirmed-discard operation.
    func requestCancelEditor() {
        leaveEditorIfNeeded { [weak self] in self?.cancelEditor() }
    }

    func cancelEditor() {
        editorEditingCardId = nil
        editorSourceTempId = nil
        resetEditorValidation()
        page = editorReturnPage
    }

    private func resetEditorValidation() {
        editorValidationAttempt = 0
        editorError = nil
    }

    func navigate(to destination: DeckPage) {
        guard page != destination else { return }
        leaveEditorIfNeeded { [weak self] in self?.page = destination }
    }

    /// 编辑页当前草稿的规范形态。
    ///
    /// 保存与「有没有改动」共用它：两处各写一份判断，迟早会出现「提示没改动但其实改了」
    /// 或者反过来的情况。
    private var editorDraft: (
        title: String,
        command: String,
        shell: String?,
        environment: [String: String],
        workingDirectory: String?
    ) {
        let title = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typographic punctuation from the pasteboard (or an older macOS substitution)
        // would make the shell treat the line differently than the user sees it.
        let command = ShellTextNormalizer.normalize(editorCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = editorShell == "default" ? nil : editorShell
        let environment = EnvironmentParser.parse(ShellTextNormalizer.normalize(editorEnvironment))
        let workingDirectory = ShellTextNormalizer.normalize(editorWorkingDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, command, shell, environment,
                workingDirectory.isEmpty ? nil : workingDirectory)
    }

    /// Shared by both layouts: every editor exit/replacement uses the same draft comparison.
    var editorHasUnsavedChanges: Bool {
        guard case .editor = page else { return false }
        let draft = editorDraft
        if let id = editorEditingCardId, let card = card(for: id) {
            return draft.title != card.title
                || draft.command != card.command
                || draft.shell != card.shellOverride
                || draft.environment != card.environment
                || draft.workingDirectory != card.workingDirectory
                || editorAutoRun != card.autoRun
        }
        // 新建：填过任何一项就算有改动（空表单直接离开不该被拦）。
        return !draft.title.isEmpty
            || !draft.command.isEmpty
            || !draft.environment.isEmpty
            || draft.workingDirectory != nil
            || draft.shell != nil
            || editorAutoRun
    }

    /// One guard for editor exits, navigation and replacing the draft in either layout.
    func leaveEditorIfNeeded(_ proceed: @escaping () -> Void) {
        guard editorHasUnsavedChanges else {
            proceed()
            return
        }
        alert = DeckAlert(
            title: "放弃未保存的修改？",
            message: "编辑页里还有没保存的内容，离开后这些改动会丢失。",
            confirmTitle: "放弃修改",
            destructive: true,
            saveAction: { [weak self] in
                guard let self, self.saveEditor() else { return }
                proceed()
            },
            action: proceed
        )
    }

    @discardableResult
    func saveEditor() -> Bool {
        if let id = editorEditingCardId, copyIsBusy(OwnerKey(kind: .preset, ownerId: id)) { return false }
        editorValidationAttempt += 1
        editorError = nil
        let draft = editorDraft
        let title = draft.title
        let command = draft.command
        guard !title.isEmpty, !command.isEmpty else {
            return false
        }
        let shell = draft.shell
        let environment = draft.environment
        let workingDirectory = draft.workingDirectory
        // 保存成功后要落到这张卡片上（牛马模式的右侧显示它的详情）。
        var savedCardId: String?

        if let id = editorEditingCardId, var card = card(for: id) {
            card.title = title
            card.command = command
            card.shellOverride = shell
            card.workingDirectory = workingDirectory
            card.environment = environment
            card.autoRun = editorAutoRun
            card.updatedAt = Date()
            do {
                try store.save(card)
                if let index = cards.firstIndex(where: { $0.id == id }) { cards[index] = card }
                savedCardId = id
                showNotice("快捷指令已保存。运行中的终端继续使用原配置。")
            } catch {
                editorError = "保存失败：\(error)"
                return false
            }
        } else {
            let card = PresetCard(
                title: title,
                command: command,
                shellOverride: shell,
                workingDirectory: workingDirectory,
                environment: environment,
                autoRun: editorAutoRun
            )
            do {
                try store.save(card)
                cards.append(card)
                savedCardId = card.id
                showNotice("快捷指令已添加。")
            } catch {
                editorError = "保存失败：\(error)"
                return false
            }
        }
        editorEditingCardId = nil
        editorSourceTempId = nil
        // 牛马模式没有「列表页」可回：保存完就选中这张卡片，右侧直接看它的详情。
        if workhorseMode.isOn, let savedCardId {
            let key = OwnerKey(kind: .preset, ownerId: savedCardId)
            // 新卡片可能落在一个被折叠起来的菜单里，那就先把它露出来。
            expandWorkhorseMenu(.preset)
            page = .detail(key)
        } else {
            page = .presets
        }
        return true
    }

    func requestDeleteCard(_ card: PresetCard) {
        let key = OwnerKey(kind: .preset, ownerId: card.id)
        if isDisposableCopy(key) { removeCopy(key); return }
        guard !copyIsBusy(key) else { return }
        pendingDeletion = PendingDeletion(key: key, title: card.title, running: isRunning(key))
    }

    func requestDeleteTemp(_ temp: TempTerminal) {
        let key = OwnerKey(kind: .temp, ownerId: temp.id)
        if isDisposableCopy(key) { removeCopy(key); return }
        guard !copyIsBusy(key) else { return }
        pendingDeletion = PendingDeletion(key: key, title: temp.title, running: isRunning(key))
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// Runs the deletion the card asked for. Nothing here waits for the sheet or the
    /// transition: by the time this returns the row is already gone from the store.
    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        if pending.key.kind == .preset, page == .editor,
           editorEditingCardId == pending.key.ownerId, editorHasUnsavedChanges {
            alert = DeckAlert(title: "删除正在编辑的快捷指令？",
                              message: "未保存的修改也会丢失。取消可继续编辑。",
                              confirmTitle: "删除并放弃修改", destructive: true) { [weak self] in
                self?.cancelEditor()
                self?.confirmDeletion()
            }
            return
        }
        pendingDeletion = nil
        let key = pending.key
        // Collect every session this owner has before the DB rows disappear. The engine
        // may still finalize a killed PTY asynchronously; forgetting the owner first stops
        // it from writing a fresh session row for the card we are deleting.
        let sessionIDs = Set(((try? store.sessions(kind: key.kind, ownerId: key.ownerId)) ?? []).map(\.id)
            + engine.allRuntimes.filter { $0.key == key }.map(\.sessionId))
        if let runtime = engine.runtime(for: key) {
            engine.forceStop(sessionId: runtime.sessionId)
        }
        removedSessionIDs.formUnion(sessionIDs)
        discardCachedSessions(sessionIDs)
        engine.forgetRemovedOwner(key)
        do {
            switch key.kind {
            case .preset:
                try store.deleteCard(id: key.ownerId)
                lastRuntime[key] = nil
                storedLastSession[key] = nil
                if editorEditingCardId == key.ownerId {
                    editorEditingCardId = nil
                    editorSourceTempId = nil
                    resetEditorValidation()
                    if page == .editor { page = .presets }
                }
                pendingRestart[key] = nil
                let fallback = workhorseFallback(after: key)
                if case .detail(let current) = page, current == key {
                    page = workhorseMode.isOn ? (fallback.map { .detail($0) } ?? .presets) : .presets
                }
                if case .history(let current, _) = page, current == key {
                    page = workhorseMode.isOn ? (fallback.map { .detail($0) } ?? .presets) : .presets
                }
            case .temp:
                try store.deleteTemp(id: key.ownerId)
                lastRuntime[key] = nil
                storedLastSession[key] = nil
                let fallback = workhorseFallback(after: key)
                if case .detail(let current) = page, current == key {
                    page = workhorseMode.isOn ? (fallback.map { .detail($0) } ?? .temps) : .temps
                }
                if case .history(let current, _) = page, current == key {
                    page = workhorseMode.isOn ? (fallback.map { .detail($0) } ?? .temps) : .temps
                }
                if editorSourceTempId == key.ownerId {
                    editorSourceTempId = nil
                    editorReturnPage = .temps
                }
            }
            refreshUsage()
            beginVanish(key)
            showNotice("“\(pending.title)”已删除。")
        } catch {
            showError("删除失败：\(error)")
        }
    }

    /// The transition for a card the store has already deleted: the card stays in the list
    /// while the burst plays, and only then does the grid close the gap.
    ///
    /// The deletion itself is not delayed — by the time this runs the row is gone from the
    /// database, so quitting the app mid-transition still leaves the card deleted.
    private func beginVanish(_ key: OwnerKey) {
        let burst = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? DeleteBurst.reducedMotion()
            : DeleteBurst.make()
        vanishing[key] = CardVanish(burst: burst, startedAt: nil)
        startClock(for: key)
    }

    /// Starts a card's transition on the first free turn of the main queue.
    ///
    /// Confirming the alert leaves the main queue stalled while the dialog animates away —
    /// measured at ~280ms, with every block queued in that window firing at once when it lets
    /// go. The particle field is drawn on the main thread (SwiftUI `Canvas`), so a transition
    /// started inside that window paints one frame and then freezes, which is exactly the
    /// stutter at the start of the animation. The card's own fade is Core Animation driven and
    /// would survive, but a burst that begins halfway through a fade is worse than one that
    /// begins a beat later, so both wait for the window to be able to paint.
    ///
    /// The deletion itself has already happened by this point: only the farewell waits.
    private func startClock(for key: OwnerKey) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      var record = self.vanishing[key],
                      record.startedAt == nil else { return }
                record.startedAt = Date()
                self.vanishing[key] = record
                // A main-queue timer rather than a `Task` sleep: a concurrency continuation
                // scheduled from here lands ~300ms late for the same reason.
                DispatchQueue.main.asyncAfter(deadline: .now() + record.burst.lifetime) { [weak self] in
                    MainActor.assumeIsolated { self?.finishVanish(key) }
                }
            }
        }
    }

    /// Takes a card that has finished its transition out of the list, and lets the grid ease
    /// the remaining cards into the gap.
    private func finishVanish(_ key: OwnerKey) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                      ? nil : .easeInOut(duration: DeleteBurst.reflow)) {
            fileBrowser.remove([key])
            cards.removeAll { $0.id == key.ownerId }
            temps.removeAll { $0.id == key.ownerId }
        }
        // The tile can still be on screen while the gap closes, so its record outlives the
        // reflow rather than being cleared in the same beat as the removal.
        DispatchQueue.main.asyncAfter(deadline: .now() + DeleteBurst.reflow + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.vanishing[key] = nil }
        }
    }

    // MARK: - Title rename

    func isRenaming(_ key: OwnerKey, in source: TitleRenameSource) -> Bool {
        renamingKey == key && renameSource == source
    }

    func beginRename(_ key: OwnerKey, source: TitleRenameSource = .detail) {
        guard !copyIsBusy(key) else { return }
        guard !isRenaming(key, in: source) else { return }
        commitRename()
        renameSource = source
        switch key.kind {
        case .preset: renameText = card(for: key.ownerId)?.title ?? ""
        case .temp: renameText = temp(for: key.ownerId)?.title ?? ""
        }
        renamingKey = key
    }

    func commitRename() {
        guard let key = renamingKey else { return }
        guard !copyIsBusy(key) else { cancelRename(); return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingKey = nil
        guard !name.isEmpty else { return }
        do {
            switch key.kind {
            case .preset:
                guard var card = card(for: key.ownerId) else { return }
                card.title = name
                card.updatedAt = Date()
                try store.save(card)
                if let index = cards.firstIndex(where: { $0.id == key.ownerId }) { cards[index] = card }
            case .temp:
                guard var temp = temp(for: key.ownerId) else { return }
                temp.title = name
                try store.save(temp)
                if let index = temps.firstIndex(where: { $0.id == key.ownerId }) { temps[index] = temp }
            }
            if var runtime = lastRuntime[key] {
                runtime.title = name
                lastRuntime[key] = runtime
            }
            showNotice("名称已更新。")
        } catch {
            showError("重命名失败：\(error)")
        }
    }

    func cancelRename() { renamingKey = nil }

    // MARK: - History

    func loadHistoryEntries(for key: OwnerKey) {
        historyEntries = ((try? store.sessions(kind: key.kind, ownerId: key.ownerId)) ?? []).filter(\.isFinished)
    }

    func requestClearHistory() {
        alert = DeckAlert(
            title: "清理全部已结束终端的历史记录？",
            message: "运行中的终端不会受影响；快捷指令卡片和终端本身会保留。",
            confirmTitle: "清理",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            do {
                _ = try self.store.clearFinishedHistory()
                self.historyEntries = []
                for task in self.archiveLoadTasks.values { task.cancel() }
                self.archiveLoadTasks.removeAll()
                self.activeArchiveSessionID = nil
                self.archiveScenes.removeAll()
                self.archiveSceneOrder.removeAll()
                self.lastRuntime = self.lastRuntime.filter { _, runtime in runtime.status.isAlive }
                if case .history(let key, _) = self.page { self.page = .history(key, nil) }
                self.refreshStoredSessions()
                self.refreshUsage()
                self.showNotice("历史记录已清理。")
            } catch {
                self.showError("清理失败：\(error)", retry: { [weak self] in self?.requestClearHistory() })
            }
        }
    }

    // MARK: - 牛马模式

    /// 右侧内容区现在展示的终端（详情或历史）。没有就是 nil——列表页、编辑页与设置页都算。
    var currentDetailKey: OwnerKey? {
        switch page {
        case .detail(let key), .history(let key, _): return key
        default: return nil
        }
    }

    func enterWorkhorseMode() { changeWorkhorseMode(.on) }
    func exitWorkhorseMode() { changeWorkhorseMode(.off) }

    func changeWorkhorseMode(_ mode: WorkhorseMode) {
        guard workhorseMode != mode else { return }
        leaveEditorIfNeeded { [weak self] in self?.setWorkhorseMode(mode) }
    }

    private func setWorkhorseMode(_ mode: WorkhorseMode) {
        guard workhorseMode != mode else { return }
        workhorseMode = mode
        DeckTheme.palette = mode.isOn ? .workhorse : .standard
        do {
            try store.setString(mode.rawValue, forKey: WorkhorseMode.key)
        } catch {
            showError("保存设置失败：\(error)")
        }
        // 换的是「怎么摆」，不是「在跑什么」：不动任何会话，只重新决定选中项与落点。
        closeTagPicker()
        exitFullscreen()
        if mode.isOn {
            // 选中项自动跟随当前页面，进出模式不另存一份可能过期的导航状态。
            workhorseCollapsedMenus = []
            if let key = currentDetailKey { revealWorkhorseItem(key) }
            expandWorkhorseDetail()
        }
        // Settings is an entry point, not the destination of a layout change. Keep an
        // open terminal in context; otherwise show the new mode's home/list immediately.
        if case .settings = page { page = .presets }
        if case .editor = page { page = .presets }
        showNotice(mode.isOn ? "已进入牛马模式。" : "已退出牛马模式。")
    }

    /// 回到首页只改变导航；终端继续运行，编辑页仍沿用未保存提醒。
    func goHome() {
        leaveEditorIfNeeded { [weak self] in
            guard let self else { return }
            self.cancelDeletion()
            self.closeTagPicker()
            self.exitFullscreen()
            self.page = .presets
        }
    }

    /// 首页的入口只导航。已清理的历史回退详情，不借机启动或重启会话。
    func openWorkhorseHome(_ destination: WorkhorseHomeDestination) {
        leaveEditorIfNeeded { [weak self] in
            guard let self else { return }
            let key: OwnerKey
            switch destination {
            case .detail(let owner), .history(let owner, _): key = owner
            }
            guard key.kind == .preset ? self.card(for: key.ownerId) != nil : self.temp(for: key.ownerId) != nil else { return }
            if case .history(_, let sessionID) = destination,
               key.kind == .preset, let record = try? self.store.session(id: sessionID),
               record.kind == key.kind, record.ownerId == key.ownerId, record.isFinished {
                self.loadHistoryEntries(for: key)
                self.page = .history(key, sessionID)
            } else {
                self.page = .detail(key)
            }
        }
    }

    /// 牛马模式里点一行：右侧换成它的详情，左侧跟着高亮。编辑页有未保存改动时先问一句。
    func workhorseSelect(_ key: OwnerKey, renamingTitle: Bool = false) {
        // 正在输入的标题由那一行的失焦回调落盘（下一轮提交，好让回到展示模式的动画演完），
        // 这里再同步提交一次就等于把输入框和这一帧一起换掉——那正是「突然消失」的原因。
        leaveEditorIfNeeded { [weak self] in
            guard let self else { return }
            self.page = .detail(key)
            // 分身卡片没有双击重命名：它只是「本次」的一份配置，名字归原卡。
            if renamingTitle, !self.isDisposableCopy(key) {
                self.beginRename(key, source: .workhorseList)
            }
        }
    }

    /// 左栏折叠的动画：模型改折叠状态时由它来驱动（点菜单行、点标签块头都走这里）。
    /// 处所与时长和 `WorkhorseCollapse` 保持一致，开启「减弱动态效果」时置空。
    private var collapseAnimation: Animation? {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || WorkhorseCollapse.disabled) ? nil : WorkhorseCollapse.animation
    }

    /// 点菜单行＝折叠 / 展开，不是切页面。动画归这里：左栏四处折叠共用同一段
    /// （见 `WorkhorseCollapse`），「减弱动态效果」时置空。
    func toggleWorkhorseMenu(_ kind: SessionKind) {
        withAnimation(collapseAnimation) {
            if workhorseCollapsedMenus.contains(kind) {
                workhorseCollapsedMenus.remove(kind)
            } else {
                workhorseCollapsedMenus.insert(kind)
            }
        }
    }

    /// 让某个菜单展开（保存完新卡片、新建终端之后都要能看见它）。
    func expandWorkhorseMenu(_ kind: SessionKind) {
        workhorseCollapsedMenus.remove(kind)
    }

    /// Reveal destinations before scrolling; a folded row does not exist in the view tree.
    private func revealWorkhorseItem(_ key: OwnerKey) {
        guard workhorseMode.isOn else { return }
        expandWorkhorseMenu(key.kind)
        guard key.kind == .preset else { return }
        let bucket = tagID(for: key) ?? Self.untaggedBucketID
        if collapsedTagIds.remove(bucket) != nil { persistCollapsedTags() }
    }

    /// 新建终端：右侧看它的详情，左侧也要能看见它。
    func createWorkhorseTempTerminal() {
        createTempTerminal()
    }

    /// 拖拽过程中只改内存里的比例（每一帧写一次设置没有必要），抬手时 `persist: true`。
    func setWorkhorseSidebarRatio(_ ratio: Double, persist: Bool) {
        workhorseSidebarRatio = (ratio.isFinite && ratio > 0)
            ? ratio
            : WorkhorseLayout.defaultRatio
        guard persist else { return }
        do {
            try store.setString(WorkhorseLayout.storageValue(workhorseSidebarRatio),
                                forKey: WorkhorseLayout.sidebarRatioKey)
        } catch {
            showError("保存面板宽度失败：\(error)")
        }
    }

    /// 双击分隔线：回到默认比例（默认窗口尺寸下就是 296pt）。
    func resetWorkhorseSidebarRatio() {
        setWorkhorseSidebarRatio(WorkhorseLayout.defaultRatio, persist: true)
    }

    /// 拖动只提交标签和顺序；当前页面、选中项、终端与历史一律保持原样。
    @discardableResult
    func moveWorkhorseCard(_ id: String, to destination: CardDropDestination) -> Bool {
        guard removingCopies.isEmpty else { return false }
        do {
            cards = try store.movePresetCard(id: id, to: destination)
            return true
        } catch {
            showError("移动卡片失败：\(error)")
            return false
        }
    }

    /// 删掉正在看的那一项之后，左侧该选谁：同一菜单里它的下一项，没有就上一项，
    /// 再没有就是空态。返回 nil 表示没有可落的地方。
    ///
    /// 必须在数组真正移除那一项**之前**调用：这里要按它原来的位置找邻居。
    private func workhorseFallback(after key: OwnerKey) -> OwnerKey? {
        let ids = key.kind == .preset ? cards.map(\.id) : temps.map(\.id)
        let remaining = ids.filter { $0 != key.ownerId }
        guard !remaining.isEmpty else { return nil }
        let index = ids.firstIndex(of: key.ownerId) ?? 0
        return OwnerKey(kind: key.kind, ownerId: remaining[min(index, remaining.count - 1)])
    }

    // MARK: - Card display mode

    func displayMode(for kind: SessionKind) -> CardDisplayMode {
        cardModes[kind] ?? .wide
    }

    /// Switching only ever touches this menu's own setting.
    func setDisplayMode(_ mode: CardDisplayMode, for kind: SessionKind) {
        guard displayMode(for: kind) != mode else { return }
        cardModes[kind] = mode
        do {
            try store.setString(mode.rawValue, forKey: CardDisplay.key(for: kind))
        } catch {
            showError("保存卡片样式失败：\(error)")
        }
    }

    func toggleDisplayMode(for kind: SessionKind) {
        setDisplayMode(displayMode(for: kind).other, for: kind)
    }

    func setDefaultShell(_ shell: String) {
        guard ShellLocator.isSupported(shell) else { return }
        defaultShell = shell
        do {
            try store.setString(shell, forKey: "default_shell")
            showNotice("默认 Shell 已设为 \(shell)。")
        } catch {
            showError("保存设置失败：\(error)")
        }
    }

    // MARK: - Fullscreen panel

    /// Workhorse detail defaults to expanded; history starts with navigation visible.
    private func expandWorkhorseDetail() {
        guard workhorseMode.isOn, case .detail(let key) = page, fullscreenKey != key else { return }
        fullscreenKey = key
    }

    /// True while this terminal's panel fills the content area.
    func isFullscreen(_ key: OwnerKey) -> Bool {
        PanelLayout.isFullscreen(current: key, expanded: fullscreenKey)
    }

    func toggleFullscreen(_ key: OwnerKey) {
        fileBrowser.presentationChanged()
        fullscreenKey = isFullscreen(key) ? nil : key
    }

    func exitFullscreen() {
        guard fullscreenKey != nil else { return }
        fullscreenKey = nil
    }

    /// Shared with the window monitor and integration checks. Native modal/picker handlers
    /// own their Escape; a focused PTY keeps ordinary Escape even when expanded.
    func consumeDeckEscape(terminalHasFocus: Bool = false) -> Bool {
        guard alert == nil else { return false }
        if quickNavigationPresented { closeQuickNavigation(); return true }
        guard tagPicker == nil else { return false }
        if pendingDeletion != nil { cancelDeletion(); return true }
        if fileBrowser.consumeEscape() { return true }
        if renamingKey != nil { cancelRename(); return true }
        if !terminalHasFocus, sidebar.consumeEscape() { return true }
        guard !terminalHasFocus, let key = currentDetailKey, isFullscreen(key) else { return false }
        exitFullscreen()
        return true
    }

    // MARK: - Terminal font size

    private static let terminalFontSizeKey = "terminal_font_size"
    private static let terminalFontSizeModeKey = "terminal_font_size_mode"

    func setTerminalFontSize(_ size: Double, isCustom: Bool) {
        let clamped = TerminalFontSize.clamp(size)
        let sizeChanged = clamped != terminalFontSize
        let modeChanged = isCustom != terminalFontSizeIsCustom
        guard sizeChanged || modeChanged else { return }
        terminalFontSize = clamped
        terminalFontSizeIsCustom = isCustom
        do {
            if sizeChanged {
                try store.setString(TerminalFontSize.storageValue(clamped), forKey: Self.terminalFontSizeKey)
            }
            if modeChanged {
                try store.setString(isCustom ? "custom" : "preset", forKey: Self.terminalFontSizeModeKey)
            }
        } catch {
            showError("保存设置失败：\(error)")
        }
    }

    // MARK: - Tags

    private static let collapsedTagsKey = "collapsed_tags"

    /// Blocks for one menu. Both menus use this: the split is identical, only the cards differ.
    func tagSections(for kind: SessionKind) -> [TagSection<PresetCardOrTemp>] {
        switch kind {
        case .preset:
            return CardGrouping.sections(items: cards.map(PresetCardOrTemp.preset), tags: tags) { $0.tagId }
        case .temp:
            return CardGrouping.sections(items: temps.map(PresetCardOrTemp.temp), tags: tags) { $0.tagId }
        }
    }

    func tag(for id: String?) -> CardTag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    func tagID(for key: OwnerKey) -> String? {
        switch key.kind {
        case .preset: return card(for: key.ownerId)?.tagId
        case .temp: return temp(for: key.ownerId)?.tagId
        }
    }

    func isTagCollapsed(_ id: String) -> Bool { collapsedTagIds.contains(id) }

    /// 「未加标签」不是标签，但它也是一块，在牛马模式里同样可以折叠。
    ///
    /// 状态跟着标签那套一起存，只是用一个不可能与标签 UUID 撞车的保留字——
    /// 卡片界面不读它（那边的「未加标签」按原规则不可折），所以两边互不影响。
    private static let untaggedBucketID = "__untagged__"

    var isUntaggedBucketCollapsed: Bool { collapsedTagIds.contains(Self.untaggedBucketID) }

    func toggleUntaggedBucketCollapsed() { toggleTagCollapsed(Self.untaggedBucketID) }

    func toggleTagCollapsed(_ id: String) {
        // 与菜单行同一段折叠动画：块头箭头和它下面那一列一起动。
        withAnimation(collapseAnimation) {
            if collapsedTagIds.contains(id) {
                collapsedTagIds.remove(id)
            } else {
                collapsedTagIds.insert(id)
            }
        }
        persistCollapsedTags()
    }

    /// How many cards and terminals are filed under each tag, including tags with none.
    func tagUsageCount() -> [String: Int] {
        var counts = CardGrouping.usageCounts(items: cards) { $0.tagId }
        for (id, count) in CardGrouping.usageCounts(items: temps, tagId: { $0.tagId }) {
            counts[id, default: 0] += count
        }
        return counts
    }

    // MARK: Picker

    /// Records the list's layout. Publishing is guarded because this runs on every layout
    /// pass, and an unguarded write would re-render the list and re-trigger the pass.
    func cardFrame(for key: OwnerKey) -> CGRect? { cardFrames[key.ownerId] }

    func publishCardFrames(_ frames: [String: CGRect]) {
        guard frames != cardFrames else { return }
        cardFrames = frames
        guard var context = tagPicker else { return }
        guard let anchor = frames[context.key.ownerId] else {
            closeTagPicker()
            return
        }
        guard context.anchor != anchor else { return }
        context.anchor = anchor
        tagPicker = context
    }

    func openTagPicker(for key: OwnerKey) {
        guard !copyIsBusy(key) else { return }
        let title: String
        switch key.kind {
        case .preset: title = card(for: key.ownerId)?.title ?? ""
        case .temp: title = temp(for: key.ownerId)?.title ?? ""
        }
        // A card that has already left the list must not open a picker at an unrelated position.
        guard let anchor = cardFrames[key.ownerId] else { return }
        tagPicker = TagPickerContext(key: key, title: title, anchor: anchor)
    }

    func closeTagPicker() {
        tagPicker = nil
    }

    /// Files a card under `tagId`, or clears it with `nil`. Only the reference changes, so
    /// nothing about the card's session, history or runtime is touched.
    func assignTag(_ tagId: String?, to key: OwnerKey) {
        guard !copyIsBusy(key) else { return }
        do {
            try store.setTag(tagId, kind: key.kind, ownerId: key.ownerId)
        } catch {
            showError("保存标签失败：\(error)")
            return
        }
        applyTagLocally(tagId, to: key)
    }

    /// Creates a tag and files a card under it in one step — the picker's Return path.
    /// A name that already exists (ignoring case and whitespace) reuses that tag instead,
    /// which is what keeps "工作 " from becoming a second block called "工作".
    func createTag(named raw: String, assigningTo key: OwnerKey) {
        if let existing = TagVocabulary.match(raw, in: tags) {
            assignTag(existing.id, to: key)
            return
        }
        guard let tag = createTag(named: raw) else { return }
        assignTag(tag.id, to: key)
    }

    /// Creates a tag with no card attached (设置 › 标签 的新建入口).
    /// Returns `nil` when the name is empty, already taken, or could not be written.
    @discardableResult
    func createTag(named raw: String) -> CardTag? {
        if let existing = TagVocabulary.match(raw, in: tags) {
            showNotice("已有标签「\(existing.name)」。")
            return nil
        }
        let name: String
        do {
            name = try TagVocabulary.validate(raw, in: tags)
        } catch {
            showError("\(error)")
            return nil
        }
        let tag = CardTag(name: name, sortOrder: TagVocabulary.nextSortOrder(in: tags))
        do {
            try store.save(tag)
        } catch {
            showError("新建标签失败：\(error)")
            return nil
        }
        tags.append(tag)
        showNotice("已新建标签「\(name)」。")
        return tag
    }

    // MARK: Management

    /// Renames a tag. The cards are not touched: they point at the id, so one UPDATE moves
    /// every card in both lists to the new name.
    func renameTag(_ id: String, to raw: String) {
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        let oldName = tags[index].name
        let name: String
        do {
            name = try TagVocabulary.validate(raw, in: tags, excluding: id)
        } catch {
            showError("\(error)")
            return
        }
        guard name != oldName else { return }
        do {
            try store.renameTag(id: id, to: name)
        } catch {
            showError("重命名失败：\(error)")
            return
        }
        tags[index].name = name
        showNotice("标签「\(oldName)」已改名为「\(name)」。")
    }

    /// Deletes a tag. Its cards fall back to 未加标签; no card is deleted. The confirmation
    /// lives in the view, which is where the count is known.
    func deleteTag(_ id: String) {
        guard let tag = tag(for: id) else { return }
        let usage = tagUsageCount()[id] ?? 0
        do {
            try store.deleteTag(id: id)
        } catch {
            showError("删除标签失败：\(error)")
            return
        }
        tags.removeAll { $0.id == id }
        // Cards keep their stale `tagId` in memory until reloaded; reloading is cheaper to
        // reason about than patching every card, and the store has already cascaded to NULL.
        refreshCardsAfterTagChange()
        if collapsedTagIds.contains(id) {
            collapsedTagIds.remove(id)
            persistCollapsedTags()
        }
        showNotice(usage > 0
                   ? "已删除标签「\(tag.name)」，\(usage) 张卡片回到「未加标签」。"
                   : "已删除标签「\(tag.name)」。")
    }

    func moveTag(_ id: String, by offset: Int) {
        guard let reordered = TagVocabulary.moved(tags, id: id, by: offset) else { return }
        do {
            try store.save(reordered)
        } catch {
            showError("调整标签顺序失败：\(error)")
            return
        }
        tags = reordered
    }

    // MARK: Internals

    private func applyTagLocally(_ tagId: String?, to key: OwnerKey) {
        switch key.kind {
        case .preset:
            for index in cards.indices {
                if cards[index].id == key.ownerId { cards[index].tagId = tagId; cards[index].copy?.anchorID = nil }
                if cards[index].copy?.anchorID == key.ownerId { cards[index].copy?.anchorID = nil }
            }
        case .temp:
            for index in temps.indices {
                if temps[index].id == key.ownerId { temps[index].tagId = tagId; temps[index].copy?.anchorID = nil }
                if temps[index].copy?.anchorID == key.ownerId { temps[index].copy?.anchorID = nil }
            }
        }
    }

    /// Re-reads both lists so a deletion's `ON DELETE SET NULL` shows up everywhere at once.
    private func refreshCardsAfterTagChange() {
        do {
            cards = try store.cards()
            temps = try store.temps()
        } catch {
            showError("读取卡片失败：\(error)")
        }
    }

    private func persistCollapsedTags() {
        do {
            try store.setString(Self.encodeCollapsedTags(collapsedTagIds), forKey: Self.collapsedTagsKey)
        } catch {
            showError("保存折叠状态失败：\(error)")
        }
    }

    /// Tag ids are UUID strings, so a comma can never appear inside one.
    private static func encodeCollapsedTags(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    private static func decodeCollapsedTags(_ stored: String?) -> Set<String> {
        guard let stored, !stored.isEmpty else { return [] }
        return Set(stored.split(separator: ",").map(String.init))
    }

    func sweepExpiredTemps() {
        let expired = engine.sweepExpiredTemps()
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        fileBrowser.remove(Set(expiredSet.map { OwnerKey(kind: .temp, ownerId: $0) }))
        temps.removeAll { expiredSet.contains($0.id) }
        for id in expired {
            let key = OwnerKey(kind: .temp, ownerId: id)
            lastRuntime[key] = nil
            storedLastSession[key] = nil
            if case .detail(let current) = page, current == key { page = .temps }
            if case .history(let current, _) = page, current == key { page = .temps }
        }
        pruneOrphanedArchiveScenes()
        showNotice("已按 24 小时规则清理 \(expired.count) 个终端。")
    }

    func refreshUsage() {
        Task.detached { [store] in
            let usage = (try? store.historyUsage()) ?? HistoryUsage()
            await MainActor.run {
                self.historyUsage = usage
            }
        }
    }

    private func refreshStoredSessions() {
        for card in cards {
            let key = OwnerKey(kind: .preset, ownerId: card.id)
            storedLastSession[key] = try? store.latestSession(kind: .preset, ownerId: card.id)
        }
        for temp in temps {
            let key = OwnerKey(kind: .temp, ownerId: temp.id)
            storedLastSession[key] = try? store.latestSession(kind: .temp, ownerId: temp.id)
        }
    }

    private func refreshStoredStatus(for key: OwnerKey) {
        storedLastSession[key] = try? store.latestSession(kind: key.kind, ownerId: key.ownerId)
    }

    // MARK: - Notices

    func showNotice(_ message: String) {
        // Routine feedback must not erase an error the user has not read yet.
        guard feedback?.kind != .error else { return }
        presentNotice(DeckNotice(message: message, kind: .success))
    }

    func showError(_ message: String, retry: (() -> Void)? = nil) {
        let item = DeckNotice(message: message, kind: .error, retry: retry)
        if feedback?.kind == .error {
            guard feedback?.message != message, !queuedErrors.contains(where: { $0.message == message }) else { return }
            queuedErrors.append(item)
        } else { presentNotice(item) }
    }

    private func presentNotice(_ item: DeckNotice) {
        noticeTask?.cancel()
        feedback = item
        if item.kind == .error {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: item.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        noticeTask = Task { @MainActor [weak self] in
            var visibleTime = 0.0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, self.feedback?.id == item.id else { return }
                // Reading time only: hidden windows, hover and VoiceOver do not consume it.
                if self.noticeHovered || !NSApp.isActive || NSApp.keyWindow == nil || NSWorkspace.shared.isVoiceOverEnabled { continue }
                visibleTime += 0.2
                if visibleTime >= 3.2 { self.dismissNotice(id: item.id); return }
            }
        }
    }

    func dismissNotice(id: UUID? = nil) {
        guard id == nil || feedback?.id == id else { return }
        noticeTask?.cancel()
        feedback = nil
        if !queuedErrors.isEmpty { presentNotice(queuedErrors.removeFirst()) }
    }

    func retryNotice(id: UUID) {
        guard let item = feedback, item.id == id, let retry = item.retry else { return }
        dismissNotice(id: id)
        retry()
    }

    func openQuickNavigation() {
        guard alert == nil, !quickNavigationPresented else { return }
        quickNavigationWindow = NSApp.keyWindow
        let responder = quickNavigationWindow?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
            quickNavigationOrigin = control
        } else { quickNavigationOrigin = responder }
        closeTagPicker()
        quickNavigationPresented = true
    }

    func closeQuickNavigation(restoringFocus: Bool = true) {
        quickNavigationPresented = false
        if !restoringFocus { quickNavigationOrigin = nil; quickNavigationWindow = nil }
    }

    /// Restore after SwiftUI has unmounted the modal's field editor, not during its teardown.
    func restoreQuickNavigationFocus() {
        guard !quickNavigationPresented else { return }
        let origin = quickNavigationOrigin, window = quickNavigationWindow
        quickNavigationOrigin = nil; quickNavigationWindow = nil
        DispatchQueue.main.async { [weak origin, weak window] in
            guard let window, window.isKeyWindow, let origin else { return }
            _ = window.makeFirstResponder(origin)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? ShellLaunchError)?.message ?? "\(error)"
    }

    // MARK: - SessionEngineDelegate

    nonisolated func engine(_ engine: SessionEngine, didProduceOutput sessionId: String, bytes: [UInt8]) {
        Task { @MainActor in
            guard !self.removedSessionIDs.contains(sessionId) else { return }
            if let scene = self.liveScenes[sessionId] {
                scene.feed(bytes)
            } else if self.engine.runtime(sessionId: sessionId)?.status.isAlive == true {
                // Only a session that can still produce output may grow a backlog.
                // A late main-queue callback for a finished shell used to recreate this
                // dictionary entry after didFinish had already cleared it.
                var backlog = self.outputBacklog[sessionId] ?? []
                backlog.append(contentsOf: bytes)
                if backlog.count > Self.outputBacklogLimit {
                    backlog.removeFirst(backlog.count - Self.outputBacklogLimit)
                }
                self.outputBacklog[sessionId] = backlog
            }
        }
    }

    nonisolated func engine(_ engine: SessionEngine, didUpdate runtime: SessionRuntime) {
        Task { @MainActor in
            let key = runtime.key
            guard !self.removedSessionIDs.contains(runtime.sessionId),
                  key.kind == .preset ? self.card(for: key.ownerId) != nil : self.temp(for: key.ownerId) != nil else { return }
            // A queued restart is applied before the finished runtime is published, so
            // pressing 启动 on a failed card never flashes the idle/未运行 state.
            let queuedRestart = (runtime.status == .stopped || runtime.status == .failed)
                ? self.pendingRestart.removeValue(forKey: key)
                : nil
            self.lastRuntime[key] = runtime
            // The start notice waits for the shell to report ready.
            if let title = self.pendingStartNotice[runtime.sessionId] {
                if runtime.status == .running {
                    self.pendingStartNotice[runtime.sessionId] = nil
                    self.showNotice("“\(title)”已启动。")
                } else if runtime.status == .failed || runtime.status == .stopped {
                    self.pendingStartNotice[runtime.sessionId] = nil
                }
            }
            // Refresh the stored snapshot when the session reaches a final state.
            if runtime.status == .failed || runtime.status == .stopped {
                self.refreshStoredStatus(for: runtime.key)
            }
            if let card = queuedRestart, self.card(for: card.id) != nil {
                self.startCard(card)
            }
        }
    }

    nonisolated func engine(_ engine: SessionEngine, didFinish session: SessionRecord) {
        Task { @MainActor in
            let key = OwnerKey(kind: session.kind, ownerId: session.ownerId)
            guard !self.removedSessionIDs.contains(session.id),
                  key.kind == .preset ? self.card(for: key.ownerId) != nil : self.temp(for: key.ownerId) != nil else { return }
            self.storedLastSession[key] = session
            // The finished screen is available from the archive; keeping this scene in
            // the live LRU would retain up to 200k lines of terminal buffer per run.
            self.liveScenes.removeValue(forKey: session.id)?.suspendForHistory()
            self.liveSceneOrder.removeAll { $0 == session.id }
            self.outputBacklog[session.id] = nil
            self.typedLine[session.id] = nil
            self.lastSubmittedLine[session.id] = nil
            self.pendingStartNotice[session.id] = nil
            // A pending "重新运行" starts once the previous session is really gone.
            if let card = self.pendingRestart.removeValue(forKey: key), self.card(for: card.id) != nil {
                self.startCard(card)
            }
            if case .history(let current, _) = self.page, current == key {
                self.loadHistoryEntries(for: key)
            }
            self.pruneOrphanedArchiveScenes()
            self.refreshUsage()
        }
    }

    nonisolated func engine(_ engine: SessionEngine, didFailToRecord message: String) {
        Task { @MainActor in
            let error = "历史写入失败，当前记录可能不完整：\(message)"
            self.historyError = error
            self.showError(error)
        }
    }
}
