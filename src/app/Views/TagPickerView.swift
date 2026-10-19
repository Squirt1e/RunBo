import AppKit
import SwiftUI
import Core

/// The card a tag is being chosen for, plus its rectangle in the root view's coordinate space.
/// The root owns the picker, so regrouping cards cannot tear it down with the card's view.
struct TagPickerContext {
    let key: OwnerKey
    let title: String
    /// Top-left-based card rectangle, kept current as the list scrolls or resizes.
    var anchor: CGRect
}

/// Hand-written because `OwnerKey` publishes `Hashable`, not `Equatable`. SwiftUI uses this
/// to decide whether the picker's content changed, so it has to compare the key for real.
extension TagPickerContext: Equatable {
    static func == (lhs: TagPickerContext, rhs: TagPickerContext) -> Bool {
        lhs.key.kind == rhs.key.kind
            && lhs.key.ownerId == rhs.key.ownerId
            && lhs.title == rhs.title
            && lhs.anchor == rhs.anchor
    }
}

/// The one tag picker. Opened from a card's "…" menu and from the card's context menu, and
/// always against the same rules:
///
///   - typing filters the list;
///   - Return confirms the highlighted row — an existing tag is selected, and a name with no
///     match is created and selected, in one keystroke;
///   - a name is normalized and matched case- and width-insensitively, so "工作 ", "工作"
///     and "ＷＯＲＫ" cannot become separate blocks that look identical.
struct TagPickerPanel: View {
    @ObservedObject var model: AppModel
    let context: TagPickerContext
    let availableSize: CGSize
    let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool

    private var currentTagID: String? { model.tagID(for: context.key) }

    private enum RowKind: Equatable {
        case tag(CardTag)
        case create(String)
    }

    private struct Row: Identifiable, Equatable {
        let kind: RowKind
        var id: String {
            switch kind {
            case .tag(let tag): return "tag-\(tag.id)"
            case .create(let name): return "create-\(name)"
            }
        }
    }

    /// Existing tags whose name contains the query. An empty query lists everything, which
    /// is what makes picking one a single click for the common case.
    private var matches: [CardTag] {
        let key = TagVocabulary.matchKey(query)
        guard !key.isEmpty else { return model.tags }
        return model.tags.filter { TagVocabulary.matchKey($0.name).contains(key) }
    }

    /// The name Return would create, or `nil` when Return selects an existing tag instead.
    private var creatableName: String? {
        let name = TagVocabulary.normalized(query)
        guard !name.isEmpty else { return nil }
        return TagVocabulary.match(name, in: model.tags) == nil ? name : nil
    }

    private var rows: [Row] {
        var rows = matches.map { Row(kind: .tag($0)) }
        if let creatableName { rows.append(Row(kind: .create(creatableName))) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            ScrollViewReader { scroller in
                ScrollView { list.appScrollbars() }
                    .onChange(of: highlighted) { _, index in
                        if let index, rows.indices.contains(index) { scroller.scrollTo(rows[index].id) }
                    }
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            if currentTagID != nil { removeRow }
        }
        .frame(width: min(TagPickerLayout.width, availableSize.width))
        .padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            fieldFocused = true
            highlighted = rows.isEmpty ? nil : 0
        }
        .onChange(of: query) { _, _ in highlighted = rows.isEmpty ? nil : 0 }
        .onExitCommand(perform: onClose)
    }

    /// Keep the search and removal controls visible while a long vocabulary scrolls.
    private var listHeight: CGFloat {
        let chromeHeight: CGFloat = 81 + (currentTagID != nil ? 39 : 0)
        return min(CGFloat(max(1, rows.count)) * 30, max(0, availableSize.height - chromeHeight))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("加标签")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text("回车确认")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
        .frame(height: 16)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            TextField("搜索或新建", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($fieldFocused)
                .onSubmit(confirm)
                .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                .accessibilityHint("上下方向键选择，回车确认，Esc 关闭标签选择器")
            Text("Esc 关闭")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.panelSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(fieldFocused ? Theme.accent : Theme.line, lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("没有匹配的标签")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, isHighlighted: index == highlighted)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        Button {
            apply(row)
        } label: {
            HStack(spacing: 8) {
                switch row.kind {
                case .tag(let tag):
                    TagChip(tag: tag)
                    Spacer(minLength: 0)
                    if tag.id == currentTagID {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                case .create(let name):
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 10)
                    Text("新建「\(name)」")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? Theme.navSelection : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            let rowIndex = index(of: row)
            if inside {
                highlighted = rowIndex
            } else if highlighted == rowIndex {
                highlighted = nil
            }
        }
    }

    private func index(of row: Row) -> Int {
        rows.firstIndex { $0.id == row.id } ?? 0
    }

    private var removeRow: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.line).padding(.vertical, 6)
            Button {
                model.assignTag(nil, to: context.key)
                onClose()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 11))
                    Text("移除标签")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.destructive)
                .padding(.horizontal, 16)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let start = highlighted ?? (delta > 0 ? -1 : rows.count)
        highlighted = min(rows.count - 1, max(0, start + delta))
    }

    /// Return confirms the highlighted row, including keyboard navigation.
    /// When the typed name matches nothing, Return creates and assigns it in one step.
    private func confirm() {
        let index = highlighted ?? 0
        guard rows.indices.contains(index) else { return }
        apply(rows[index])
    }

    private func apply(_ row: Row) {
        switch row.kind {
        case .tag(let tag):
            model.assignTag(tag.id, to: context.key)
        case .create(let name):
            model.createTag(named: name, assigningTo: context.key)
        }
        onClose()
    }
}

/// Mounted above the entire workbench, not inside a card or its clipping scroll view.
struct TagPickerLayer: View {
    static let coordinateSpace = "tag-picker-root"
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { viewport in
            if let context = model.tagPicker {
                TagPickerPositionLayout(anchor: context.anchor) {
                    TagPickerPanel(
                        model: model,
                        context: context,
                        availableSize: TagPickerLayout.availableSize(in: viewport.size),
                        onClose: model.closeTagPicker
                    )
                    .id(context.key)
                    .background(TagPickerEventMonitor(onClose: model.closeTagPicker))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
            }
        }
        .clipped()
    }
}

/// Measure and place in one layout pass, without a stale screen frame or size preference.
private struct TagPickerPositionLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let frame = TagPickerLayout.frame(anchor: anchor, panelSize: panel.sizeThatFits(.unspecified),
                                         viewport: bounds.size)
        panel.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
}

/// Escape dismisses only the picker; outside clicks dismiss it and still reach the workbench.
private struct TagPickerEventMonitor: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        weak var view: NSView?
        var onClose: () -> Void
        private var monitor: Any?

        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = self.view, let window = view.window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, event.window === window {
                        self.onClose()
                        return nil
                    }
                } else if event.window !== window || !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    self.onClose()
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The tag pill: a coloured dot plus the name, on a tinted hairline pill. Used by the picker
/// and by the settings › tags list. The list's *block headers* use `TagSectionHeader`
/// instead, which carries the count and the collapse control.
struct TagChip: View {
    let tag: CardTag
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 4.5) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(tag.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 19)
        .background(
            Capsule().fill(background)
        )
        .overlay(Capsule().stroke(border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("标签 \(tag.name)")
    }

    private var tone: TagTone { TagTone.of(tag) }
    private var color: Color { tone.foreground }
    private var background: Color { tone.background }
    private var border: Color { tone.border }
}
