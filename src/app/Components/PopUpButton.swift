import AppKit
import SwiftUI

/// One row of a `PopUpControl` menu.
struct PopUpOption<Value: Hashable>: Identifiable {
    let title: String
    let value: Value

    var id: Value { value }
}

/// Host-owned state for one pop-up. The control writes where it sits; the host
/// draws the menu above its scroll view, which would otherwise clip it.
struct PopUpState: Equatable {
    var isOpen = false
    /// Control frame in the host's coordinate space (origin at its top-left).
    var anchor: CGRect = .zero
    /// Highlighted row: starts on the current value, then follows hover and ↑↓.
    var highlighted = 0
}

/// Where the control sits inside the host's named coordinate space.
struct PopUpAnchorKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Themed stand-in for a native pop-up button: a field carrying the current
/// value that opens a list of options right below itself. The open state draws
/// an accent border, matching the approved mockup.
///
/// The list itself is `PopUpMenu`, which the host must place — see
/// `CardEditorView` — so that it floats above the surrounding scroll view.
struct PopUpControl<Value: Hashable>: View {
    let options: [PopUpOption<Value>]
    @Binding var selection: Value
    @Binding var state: PopUpState
    /// Coordinate space shared with `PopUpMenu`.
    let coordinateSpace: String
    /// Read by VoiceOver, e.g. "Shell".
    var name: String = ""

    @State private var keyMonitor: Any?

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.leading, 12)
            // The chevron reads as part of the field's edge, not as a centred
            // glyph, so it keeps only a small inset (as in the mockup).
            .padding(.trailing, 9)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(state.isOpen ? Theme.accent : Theme.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(name.isEmpty ? currentTitle : "\(name)，\(currentTitle)")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PopUpAnchorKey.self,
                    value: proxy.frame(in: .named(coordinateSpace))
                )
            }
        )
        .onChange(of: state.isOpen) { _, isOpen in
            if isOpen { installKeyMonitor() } else { removeKeyMonitor() }
        }
        .onDisappear { removeKeyMonitor() }
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? "\(selection)"
    }

    private func toggle() {
        if state.isOpen {
            state.isOpen = false
        } else {
            // Opening always highlights the value in use, as the mockup shows.
            state.highlighted = options.firstIndex { $0.value == selection } ?? 0
            state.isOpen = true
        }
    }

    private func commit() {
        if options.indices.contains(state.highlighted) {
            selection = options[state.highlighted].value
        }
        state.isOpen = false
    }

    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        state.highlighted = (state.highlighted + delta + options.count) % options.count
    }

    /// The list is a plain overlay, so it needs the keys a native menu would
    /// take: ↑↓ to move, Return to commit, Escape to leave the value alone.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { event in
            guard event.type == .keyDown else {
                // Scrolling means the user is done with the list; let the page
                // have the gesture instead of dragging the list along.
                state.isOpen = false
                return event
            }
            switch event.keyCode {
            case 53: // esc
                state.isOpen = false
                return nil
            case 36, 76: // return / keypad enter
                commit()
                return nil
            case 125: // ↓
                move(1)
                return nil
            case 126: // ↑
                move(-1)
                return nil
            default:
                // Any other key means the user moved on: close, but let the key
                // reach whatever was focused before.
                state.isOpen = false
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// The list a `PopUpControl` opens, plus a full-size scrim so that the next
/// click anywhere else dismisses it (as a native menu does). Hosts add this as
/// an overlay on the view whose coordinate space the control measured.
struct PopUpMenu<Value: Hashable>: View {
    let options: [PopUpOption<Value>]
    @Binding var selection: Value
    @Binding var state: PopUpState

    private let rowHeight: CGFloat = 26
    private let rowInset: CGFloat = 12
    private let menuPadding: CGFloat = 2
    private let gap: CGFloat = 2
    private let corner: CGFloat = 8
    private let viewportInset: CGFloat = 8

    var body: some View {
        GeometryReader { viewport in
            if state.isOpen, state.anchor != .zero {
                ZStack(alignment: .topLeading) {
                    dismissLayer
                    list(in: viewport.size)
                }
            }
        }
    }

    private var dismissLayer: some View {
        // Nearly invisible, but it has to be hit-testable to catch the click.
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .onTapGesture { state.isOpen = false }
    }

    private func list(in viewport: CGSize) -> some View {
        let height = CGFloat(options.count) * rowHeight + menuPadding * 2
        let below = state.anchor.maxY + gap
        // Below the control as in the mockup, unless the viewport has no room
        // left there: then open upwards rather than off-screen.
        let top = below + height + viewportInset <= viewport.height
            ? below
            : max(viewportInset, state.anchor.minY - gap - height)

        return VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                row(option, index: index)
            }
        }
        .padding(.vertical, menuPadding)
        .frame(width: state.anchor.width)
        .background(
            RoundedRectangle(cornerRadius: corner)
                .fill(Theme.panel)
                .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: corner).stroke(Theme.line, lineWidth: 1))
        // The highlight runs edge to edge, so the rows are clipped to the menu.
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .position(x: state.anchor.midX, y: top + height / 2)
    }

    private func row(_ option: PopUpOption<Value>, index: Int) -> some View {
        let highlighted = state.highlighted == index
        return Button {
            selection = option.value
            state.isOpen = false
        } label: {
            Text(option.title)
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? Theme.selectionText : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, rowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
                .background(highlighted ? Theme.selectionFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            if inside { state.highlighted = index }
        }
        .accessibilityLabel(option.title)
        // The highlight follows the pointer; only the stored value is "selected".
        .accessibilityAddTraits(option.value == selection ? [.isSelected] : [])
    }
}
