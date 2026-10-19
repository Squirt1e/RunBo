import AppKit
import SwiftUI

struct Notice: Identifiable {
    enum Kind { case information, success, error }
    let id = UUID()
    let message: String
    let kind: Kind
    var retry: (() -> Void)? = nil
}

extension View {
    /// Feedback never participates in page layout, so neither cards nor the PTY resize.
    func appFeedback(model: AppModel) -> some View {
        overlay(alignment: .bottomTrailing) {
            FeedbackToast(model: model)
                .padding(16)
        }
    }
}

/// Errors remain until dismissed; copy always includes the complete error.
struct FeedbackToast: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let feedback = model.feedback {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: feedback.kind == .error ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(feedback.kind == .error ? Theme.red : Theme.muted)
                    .padding(.top, 2).accessibilityHidden(true)
                Group {
                    if feedback.kind == .error {
                        FeedbackMessage(message: feedback.message)
                    } else {
                        Text(feedback.message).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.text)
                if feedback.retry != nil {
                    Button("重试") { model.retryNotice(id: feedback.id) }
                        .buttonStyle(PressButtonStyle(variant: .small, fontSize: 11))
                        .accessibilityHint("仅重试这次失败的操作")
                }
                if feedback.kind == .error {
                    Button { BrowserActions.copy(feedback.message) } label: {
                        Image(systemName: "doc.on.doc").frame(width: 25, height: 24)
                    }.buttonStyle(.plain).help("复制完整错误信息").accessibilityLabel("复制完整错误信息")
                }
                Button { model.dismissNotice(id: feedback.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 25, height: 24)
                }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 480)
            .fixedSize(horizontal: false, vertical: true)
            .background(feedback.kind == .error ? Theme.redBackground : Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(feedback.kind == .error ? Theme.redBorder : Theme.line)
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            .onHover { model.noticeHovered = $0 }
            .onDisappear { model.noticeHovered = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(feedback.kind == .error ? "操作未完成" : "操作反馈")
        }
    }
}

private struct FeedbackErrorHeight: PreferenceKey {
    static var defaultValue: CGFloat = 18
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Short errors use one line of space; long errors scroll without truncating the source.
private struct FeedbackMessage: View {
    let message: String
    @State private var textHeight: CGFloat = 18
    var body: some View {
        ScrollView {
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: FeedbackErrorHeight.self, value: geometry.size.height)
                })
                .appScrollbars()
        }
        .frame(height: min(96, max(18, textHeight)))
        .onPreferenceChange(FeedbackErrorHeight.self) { value in
            let height = ceil(value)
            if textHeight != height { textHeight = height }
        }
    }
}
