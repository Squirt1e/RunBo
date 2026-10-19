import AppKit
import SwiftUI
import Core

struct DirectoryCompletionState: Equatable {
    var matches: [String] = []
    var highlighted = 0
    var anchor: CGRect = .zero
    /// A mouse selection is delivered to the native field so editing keeps focus.
    var selectedPath: String?
}

struct DirectoryCompletionAnchorKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// A native single-line field, with a separately drawn (never stored) suggestion.
struct DirectoryCompletionField: NSViewRepresentable {
    @Binding var text: String
    @Binding var state: DirectoryCompletionState

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, state: $state) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = DirectoryCompletionCell(textCell: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = NSColor(Theme.text)
        field.placeholderString = "例如 ~/Projects"
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("工作目录")
        field.setAccessibilityHelp("灰色文字是文件夹建议。Tab 补全，方向键选择，Esc 收起。")
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.state = $state
        field.textColor = NSColor(Theme.text)
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? DirectoryGhostEditor {
                coordinator.synchronizing = true
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                coordinator.synchronizing = false
            }
            DispatchQueue.main.async { [weak coordinator] in coordinator?.refresh() }
        }
        coordinator.highlighted = state.highlighted
        coordinator.drawSuggestion()
        if let selected = state.selectedPath, coordinator.pendingSelection != selected {
            coordinator.pendingSelection = selected
            DispatchQueue.main.async { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.state.wrappedValue.selectedPath = nil
                coordinator.pendingSelection = nil
                guard coordinator.field?.window != nil else { return }
                coordinator.field?.window?.makeFirstResponder(coordinator.field)
                coordinator.accept(selected)
            }
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.cancelQuery()
        (field.currentEditor() as? DirectoryGhostEditor)?.selectionChanged = nil
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var state: Binding<DirectoryCompletionState>
        weak var field: NSTextField?
        var highlighted = 0
        var pendingSelection: String?
        var synchronizing = false
        private weak var activeEditor: DirectoryGhostEditor?
        private var matches: [String] = []
        private var query: String?
        private var dismissedQuery: String?
        private var generation = 0
        private var work: DispatchWorkItem?
        private var pendingTab: String?

        init(text: Binding<String>, state: Binding<DirectoryCompletionState>) {
            self.text = text
            self.state = state
        }

        private var editor: DirectoryGhostEditor? { field?.currentEditor() as? DirectoryGhostEditor }
        private var canSuggest: Bool {
            guard let editor, editor.window?.firstResponder === editor,
                  !editor.hasMarkedText() else { return false }
            let selection = editor.selectedRange()
            return selection.length == 0 && selection.location == (editor.string as NSString).length
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            activeEditor = editor
            editor?.selectionChanged = { [weak self] in self?.refresh() }
            refresh()
        }

        func controlTextDidChange(_ notification: Notification) {
            text.wrappedValue = editor?.string ?? field?.stringValue ?? ""
            refresh()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            activeEditor?.selectionChanged = nil
            activeEditor?.suggestion = ""
            activeEditor = nil
            cancelQuery()
            query = nil
            matches = []
            publish([])
        }

        func refresh() {
            guard !synchronizing, let editor else { return }
            let input = editor.string
            if let dismissedQuery, dismissedQuery != input { self.dismissedQuery = nil }
            guard canSuggest, dismissedQuery != input else {
                drawSuggestion()
                publish([])
                return
            }
            guard query != input else {
                drawSuggestion()
                publish(matches)
                return
            }
            cancelQuery()
            query = input
            matches = []
            highlighted = 0
            drawSuggestion()
            publish([])
            let token = generation
            let task = DispatchWorkItem { [weak self] in
                let values = DirectoryCompletion.matches(for: input)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.editor?.string == input,
                          self.dismissedQuery != input else { return }
                    self.work = nil
                    self.matches = values
                    self.highlighted = 0
                    self.drawSuggestion()
                    self.publish(self.canSuggest ? values : [])
                    if self.pendingTab == input {
                        self.pendingTab = nil
                        guard self.canSuggest else { return }
                        if let first = values.first {
                            self.accept(first)
                        } else if let field = self.field {
                            field.window?.selectNextKeyView(field)
                        }
                    }
                }
            }
            work = task
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1, execute: task)
        }

        func cancelQuery() {
            generation += 1
            work?.cancel()
            work = nil
            pendingTab = nil
        }

        func drawSuggestion() {
            guard let editor else { return }
            let input = editor.string
            if canSuggest, dismissedQuery != input,
               matches.indices.contains(highlighted),
               let suffix = DirectoryCompletion.suffix(for: input, candidate: matches[highlighted]) {
                editor.suggestion = suffix
            } else {
                editor.suggestion = ""
            }
        }

        private func publish(_ values: [String]) {
            var next = state.wrappedValue
            next.matches = values
            next.highlighted = highlighted
            if next != state.wrappedValue { state.wrappedValue = next }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let the input method handle composition and Shift-Tab keep its usual focus traversal.
            guard canSuggest else { return false }
            // AppKit can dispatch a key before selection/change notifications have
            // reached the coordinator; never accept candidates for an older prefix.
            refresh()
            switch selector {
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                guard dismissedQuery != textView.string else { return false }
                if selector == #selector(NSResponder.insertTab(_:)), work != nil, !textView.string.isEmpty {
                    // A quick Tab must complete even before the debounced disk lookup returns.
                    pendingTab = textView.string
                    return true
                }
                guard matches.indices.contains(highlighted) else { return false }
                accept(matches[highlighted])
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                guard matches.count > 1, dismissedQuery != textView.string else { return false }
                let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
                highlighted = (highlighted + delta + matches.count) % matches.count
                drawSuggestion()
                publish(matches)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !matches.isEmpty || work != nil else { return false }
                dismissedQuery = textView.string
                cancelQuery()
                drawSuggestion()
                publish([])
                return true
            default:
                return false
            }
        }

        func accept(_ value: String) {
            guard let editor else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            editor.breakUndoCoalescing()
            editor.insertText(value, replacementRange: range)
            editor.breakUndoCoalescing()
            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            // `insertText` keeps native undo and sends the ordinary editing notification.
            text.wrappedValue = editor.string
            refresh()
        }
    }
}

/// Give this field its own field editor, retaining NSTextField's native scrolling,
/// selection, input method, undo and focus traversal.
final class DirectoryCompletionCell: NSTextFieldCell {
    private let ghostEditor = DirectoryGhostEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        ghostEditor.isFieldEditor = true
        ghostEditor.drawsBackground = false
        ghostEditor.isRichText = false
        ghostEditor.allowsUndo = true
        ghostEditor.isAutomaticQuoteSubstitutionEnabled = false
        ghostEditor.isAutomaticDashSubstitutionEnabled = false
        ghostEditor.isAutomaticTextReplacementEnabled = false
        ghostEditor.isAutomaticSpellingCorrectionEnabled = false
        ghostEditor.isContinuousSpellCheckingEnabled = false
        ghostEditor.isGrammarCheckingEnabled = false
        ghostEditor.smartInsertDeleteEnabled = false
        return ghostEditor
    }
}

final class DirectoryGhostEditor: NSTextView {
    var suggestion = "" { didSet { if oldValue != suggestion { needsDisplay = true } } }
    var selectionChanged: (() -> Void)?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        selectionChanged?()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { suggestion = "" }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let range = selectedRange()
        guard !suggestion.isEmpty, !hasMarkedText(), window?.firstResponder === self,
              range.length == 0, range.location == (string as NSString).length,
              let window, let font else { return }
        // AppKit supplies the caret's actual location, including horizontal scrolling
        // and variable-width/Chinese glyphs. The suffix never enters textStorage.
        let caret = convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visibleRect).addClip()
        (suggestion as NSString).draw(at: caret.origin, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Draw above the page's ScrollView so suggestions don't cover or reflow the form.
struct DirectoryCompletionMenu: View {
    @Binding var state: DirectoryCompletionState

    var body: some View {
        GeometryReader { viewport in
            if state.matches.count > 1, state.anchor != .zero {
                let height = min(CGFloat(state.matches.count) * 28 + 25, 249)
                let below = state.anchor.maxY + 3
                let top = below + height <= viewport.size.height - 8
                    ? below : max(8, state.anchor.minY - height - 3)
                VStack(spacing: 0) {
                    Text("↑↓ 选择 · Tab 补全 · Esc 收起")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(state.matches.enumerated()), id: \.element) { index, value in
                                    Button {
                                        state.selectedPath = value
                                    } label: {
                                        Label(value, systemImage: "folder")
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .foregroundStyle(index == state.highlighted ? Theme.selectionText : Theme.text)
                                            .padding(.horizontal, 10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(height: 28)
                                            .background(index == state.highlighted ? Theme.selectionFill : Color.clear)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .focusEffectDisabled()
                                    .onHover { inside in if inside { state.highlighted = index } }
                                    .id(index)
                                }
                            }
                            .appScrollbars()
                        }
                        .onChange(of: state.highlighted) { _, index in proxy.scrollTo(index) }
                    }
                }
                .frame(width: state.anchor.width, height: height)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .position(x: state.anchor.midX, y: top + height / 2)
            }
        }
    }
}
