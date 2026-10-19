import AppKit
import SwiftUI
import Core

/// Plain-text editor for shell input.
///
/// macOS text substitution must never touch a command: smart quotes turn
/// `'*.example.com'` into `‘*.example.com’` (which zsh then globs and fails on) and
/// smart dashes turn `--force` into `—-force`. This wraps `NSTextView` directly so
/// quotes, dashes, spelling and autocorrection are all off, and the text can be styled
/// like the embedded terminal.
struct ShellTextEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var fontSize: CGFloat = 12
    var minHeight: CGFloat = 78
    /// Drawn inside the empty field. The placeholder hides as soon as the caret is in
    /// the view, so the two never overlap.
    var placeholder: String?
    var placeholderColor: NSColor = .placeholderTextColor
    /// A new nonzero generation requests focus after validation, without stealing it on typing.
    var focusRequest: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView(frame: .zero)
        textView.placeholder = placeholder
        textView.placeholderColor = placeholderColor
        textView.placeholderFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        Scroller.install(in: scrollView)
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        configure(textView)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        textView.textColor = textColor
        (textView as? PlaceholderTextView)?.placeholder = placeholder
        (textView as? PlaceholderTextView)?.placeholderColor = placeholderColor
        (textView as? PlaceholderTextView)?.placeholderFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if focusRequest > 0 {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func configure(_ textView: NSTextView) {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = textColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // The surrounding SwiftUI container owns the padding so the prompt glyph and
        // the first line of text share the same baseline.
        textView.textContainerInset = NSSize(width: 1, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var lastFocusRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// `NSTextView` with a placeholder drawn where the text would start.
///
/// AppKit has no placeholder for a plain text view, and a SwiftUI `Text` behind it sits
/// on top of the insertion point, which looked like two overlapping strings. Drawing it
/// here also means it lines up with the real first line for free.
final class PlaceholderTextView: NSTextView {
    var placeholder: String?
    var placeholderColor: NSColor = .placeholderTextColor
    var placeholderFont: NSFont?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let text = placeholder, !text.isEmpty, string.isEmpty, !hasCaret else { return }
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: inset.width + padding,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2 - padding * 2),
            height: max(0, bounds.height - inset.height * 2)
        )
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: placeholderColor,
            ]
        )
    }

    /// A caret only exists while this view is the key window's first responder.
    private var hasCaret: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }
}

/// Normalises text that arrives from the pasteboard or from a macOS substitution.
/// A pasted command from Notes/Mail/WeChat often carries typographic punctuation that
/// a shell cannot use.
enum ShellTextNormalizer {
    private static let replacements: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"",
        "\u{2013}": "--", "\u{2014}": "--",
        "\u{00A0}": " ", "\u{202F}": " ",
        "\u{2026}": "...",
    ]

    static func normalize(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            if let replacement = replacements[character] {
                output += replacement
            } else {
                output.append(character)
            }
        }
        return output
    }
}
