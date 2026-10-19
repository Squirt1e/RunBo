import AppKit
import SwiftUI
import PDFKit
import WebKit
import ImageIO
import Core

private enum PreparedFilePreview {
    case text(BrowserText)
    case native(BrowserNativeSnapshot)
    case unsupported
}

struct FilePreviewLayer: View {
    let request: BrowserPreviewRequest
    let close: () -> Void
    let report: (String) -> Void
    @State private var prepared: PreparedFilePreview?
    @State private var failure: String?
    @State private var nativeFailure: String?
    @State private var htmlSource = false
    @FocusState private var previewFocused: Bool

    private var kind: BrowserPreviewKind { .classify(request.entry.name) }
    var body: some View {
        GeometryReader { geometry in
            if kind == .image {
                imageLayer(geometry)
            } else {
                cardLayer(geometry)
            }
        }
        .task(id: request.id) {
            let root = request.root, relative = request.entry.id, previewKind = kind
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> PreparedFilePreview in
                    switch previewKind {
                    case .text, .html: return .text(try BrowserText.load(root: root, relative: relative))
                    case .image, .pdf:
                        let snapshot = try BrowserFileSystem.nativeSnapshot(root: root, relative: relative)
                        if previewKind == .image {
                            guard let source = CGImageSourceCreateWithURL(snapshot.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                                throw FileBrowserError("系统无法识别这张图片，或图片已损坏。")
                            }
                            guard width.doubleValue * height.doubleValue <= 40_000_000 else {
                                throw FileBrowserError("图片超过 4000 万像素，未加载；请使用默认应用查看。")
                            }
                        }
                        return .native(snapshot)
                    case .unsupported: return .unsupported
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let preview): prepared = preview
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var previewBody: some View {
        if let failure = failure ?? nativeFailure {
            message(failure)
        } else if let prepared {
            switch prepared {
            case .text(let text):
                if kind == .html && !htmlSource {
                    if text.truncated { message("HTML 超过 1 MB；为避免渲染不完整页面，请切换到源码查看前 1 MB。") }
                    else { StaticHTMLPreview(root: request.root, relative: request.entry.id, failure: { nativeFailure = $0 }) }
                } else if text.text.isEmpty { message("空文本文件") }
                else { ReadOnlyFileText(text: text.text) }
            case .native(let snapshot):
                if kind == .pdf { SystemPDFPreview(url: snapshot.url, failure: { nativeFailure = $0 }) }
                else { SystemImagePreview(url: snapshot.url) }
            case .unsupported:
                message("不支持内嵌预览此类型（.\((request.entry.name as NSString).pathExtension)）。不执行程序或脚本。")
            }
        } else { ProgressView("正在读取…") }
    }
    private func message(_ value: String) -> some View {
        Text(value).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(24)
    }
    private var footer: String {
        if case .text(let text) = prepared {
            if text.truncated { return "已截断：仅显示前 1 MB（保留完整字符边界） · \(text.encoding)" }
            return kind == .html && !htmlSource ? "静态 HTML · 脚本 / 联网 / 导航已禁用" : "原生只读文本 · \(text.encoding)"
        }
        return ByteCountFormatter.string(fromByteCount: request.entry.size, countStyle: .file) + " · 系统组件"
    }

    /// Images are the one preview that gets the whole content area by default: the viewer is
    /// the background, and the small control strip floats above it instead of reserving a
    /// card header/footer and shrinking the image. The backdrop is translucent so the
    /// terminal stays visible (and transparent images show it through instead of black).
    private func imageLayer(_ geometry: GeometryProxy) -> some View {
        ZStack(alignment: .top) {
            // Consume clicks on the backdrop only, so the image viewer keeps its own
            // zoom/scroll interactions while no click can reach the terminal underneath.
            Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture {}
            imageBody.frame(maxWidth: .infinity, maxHeight: .infinity)
            imageChrome
        }
        .frame(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
        .clipped()
        .focusable().focused($previewFocused).focusEffectDisabled()
        .onAppear { previewFocused = true }
        .accessibilityIdentifier("file-preview-image")
    }

    @ViewBuilder private var imageBody: some View {
        if let failure = failure ?? nativeFailure {
            Text(failure).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).padding(24)
        } else if let prepared {
            switch prepared {
            case .native(let snapshot): SystemImagePreview(url: snapshot.url)
            default:
                Text("图片读取失败。").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(24)
            }
        } else {
            ProgressView("正在读取…").tint(.white).foregroundStyle(.white)
        }
    }

    private var imageChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.entry.name).font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(request.entry.relativePath).font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.68)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text("只读预览 · 滚轮缩放 · 双击复位").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
            if BrowserPreviewKind.canOpenExternally(name: request.entry.name, executable: request.entry.executable) {
                Button("默认应用打开") { BrowserActions.open(root: request.root, entry: request.entry, failure: report) }
                    .buttonStyle(.plain).foregroundStyle(.white)
            }
            Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.white)
                .help("关闭预览（Esc）").accessibilityLabel("关闭预览")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.black.opacity(0.55))
    }

    private func cardLayer(_ geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.entry.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(request.entry.relativePath).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text("只读预览").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    if kind == .html {
                        Picker("HTML", selection: $htmlSource) { Text("页面").tag(false); Text("源码").tag(true) }
                            .pickerStyle(.segmented).frame(width: 110)
                    }
                    Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 26) }
                        .buttonStyle(.plain).help("关闭预览（Esc）").accessibilityLabel("关闭预览")
                }
                .padding(16)
                Divider().overlay(Theme.line)
                previewBody.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.line)
                HStack(spacing: 10) {
                    Text(footer).foregroundStyle(Theme.muted).lineLimit(2)
                    Spacer(minLength: 0)
                    if BrowserPreviewKind.canOpenExternally(name: request.entry.name, executable: request.entry.executable) {
                        Button("默认应用打开") { BrowserActions.open(root: request.root, entry: request.entry, failure: report) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }
                    Text("Esc 关闭").foregroundStyle(Theme.muted)
                }
                .font(.system(size: 11)).padding(12)
            }
            .foregroundStyle(Theme.text)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 18)
            .frame(width: max(1, min(960, geometry.size.width - 32)), height: max(1, geometry.size.height - 32))
            // The overlay consumes clicks, including clicks that dismiss it; none hit the PTY.
            .contentShape(Rectangle()).onTapGesture {}
            .focusable().focused($previewFocused).focusEffectDisabled()
            .onAppear { previewFocused = true }
        }
    }
}

struct ReadOnlyFileText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        Scroller.install(in: scroll)
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.allowsUndo = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        scroll.documentView = view
        view.string = text
        view.sizeToFit()
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let view = nsView.documentView as? NSTextView, view.string != text { view.string = text; view.sizeToFit() }
    }
}

/// Transparent image viewer with pointer-centred wheel zoom.
///
/// `QLPreviewView` always paints its own opaque dark backdrop and does not map a mouse wheel
/// to zoom, so images use this small viewer instead. Pinch/scrollbars still come from
/// `NSScrollView`; an image that fits is shown at its natural size and centred.
final class ZoomableImagePreview: NSScrollView {
    private let imageView = NSImageView()
    private var imageSize = CGSize.zero
    private var loadedURL: URL?
    private var needsFit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        // Keep the transparent gutters allocated while zooming. Adding/removing a
        // legacy gutter during setMagnification moves the pointer's image anchor.
        // Scroller draws nothing when disabled, so fitted images still have no bars.
        autohidesScrollers = false
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 8
        let clip = CenteringClipView()
        clip.drawsBackground = false
        clip.backgroundColor = .clear
        contentView = clip
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(fitImage))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
        Scroller.install(in: self)
        verticalScroller?.knobStyle = .light
        horizontalScroller?.knobStyle = .light
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        let image = NSImage(contentsOf: url)
        imageView.image = image
        imageSize = image?.size ?? .zero
        imageView.frame = NSRect(origin: .zero, size: imageSize)
        imageView.alphaValue = 0
        needsFit = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsFit, imageSize.width > 0, imageSize.height > 0,
              bounds.width > 1, bounds.height > 1 else { return }
        needsFit = false
        fitImage()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        // Precise trackpad deltas arrive in much smaller units than a notched wheel.
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.02 : 0.12))
        zoom(by: factor, at: imageView.convert(event.locationInWindow, from: nil))
    }

    func zoom(by factor: CGFloat, at point: NSPoint? = nil) {
        guard factor.isFinite, factor > 0, imageSize.width > 0, imageSize.height > 0 else { return }
        let next = min(maxMagnification, max(minMagnification, magnification * factor))
        guard abs(next - magnification) > 0.0001 else { return }
        let anchor = point ?? NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        setMagnification(next, centeredAt: anchor)
    }

    @objc private func fitImage() {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 1, bounds.height > 1 else { return }
        let available = CGSize(width: max(1, bounds.width - 32), height: max(1, bounds.height - 32))
        let fit = min(available.width / imageSize.width, available.height / imageSize.height)
        setMagnification(min(1, max(minMagnification, fit)),
                         centeredAt: NSPoint(x: imageSize.width / 2, y: imageSize.height / 2))
        imageView.alphaValue = 1
    }
}

/// Keeps an image smaller than the viewport centred while still allowing free scrolling
/// once the user zooms past the viewport.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let document = documentView.frame
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

private struct SystemImagePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> ZoomableImagePreview {
        let view = ZoomableImagePreview()
        view.load(url: url)
        return view
    }
    func updateNSView(_ view: ZoomableImagePreview, context: Context) { view.load(url: url) }
    static func dismantleNSView(_ view: ZoomableImagePreview, coordinator: ()) { view.documentView = nil }
}

/// PDFKit owns/rebuilds its internal scroll view. Configure after each layout rather
/// than assuming the document scroll view already exists in makeNSView.
final class PDFPreviewView: PDFView {
    override func layout() {
        super.layout()
        installScrollbars(in: self)
    }

    private func installScrollbars(in view: NSView) {
        if let scroll = view as? NSScrollView { Scroller.install(in: scroll) }
        for child in view.subviews { installScrollbars(in: child) }
    }
}

private struct SystemPDFPreview: NSViewRepresentable {
    let url: URL
    let failure: (String) -> Void
    func makeNSView(context: Context) -> PDFView {
        let view = PDFPreviewView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        if let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 { view.document = document }
        else { DispatchQueue.main.async { failure("PDF 已损坏、加密或无法读取。") } }
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}

/// No file:// entitlement: WebKit sees only a private scheme with a bounded, read-only handler.
/// Content rules block every request except that scheme, and CSP provides a second boundary.
struct StaticHTMLPreview: NSViewRepresentable {
    let root: URL
    let relative: String
    let failure: (String) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let mainURL: URL
        let failure: (String) -> Void
        var allowedInitial = false
        var active = true
        init(mainURL: URL, failure: @escaping (String) -> Void) { self.mainURL = mainURL; self.failure = failure }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !allowedInitial, navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url == mainURL {
                allowedInitial = true; decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.isForMainFrame && navigationResponse.response.url == mainURL
                            && navigationResponse.canShowMIMEType ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if active && (error as NSError).code != NSURLErrorCancelled { failure("HTML 加载失败：\(error.localizedDescription)") }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { failure("HTML 预览进程已结束；可切换源码查看。") } }
    }

    func makeCoordinator() -> Coordinator {
        var url = URLComponents()
        url.scheme = BrowserHTMLPolicy.scheme; url.host = "local"
        url.path = "/" + (relative as NSString).lastPathComponent
        return Coordinator(mainURL: url.url!, failure: failure)
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let parent = (relative as NSString).deletingLastPathComponent
        // Keep the original root descriptor boundary, including for a replaced HTML parent.
        configuration.setURLSchemeHandler(HTMLResourceHandler(root: root, parent: parent,
                                                              main: (relative as NSString).lastPathComponent),
                                          forURLScheme: BrowserHTMLPolicy.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false; view.allowsBackForwardNavigationGestures = false
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^app-preview://local/"},"action":{"type":"ignore-previous-rules"}}]
        """
        let coordinator = context.coordinator
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "runbo-static-html-v1", encodedContentRuleList: rules) { [weak view] list, error in
            guard coordinator.active, let view else { return }
            guard let list, error == nil else { coordinator.failure("无法启用 HTML 安全规则；请切换源码查看。"); return }
            view.configuration.userContentController.add(list)
            view.load(URLRequest(url: coordinator.mainURL))
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
}

private final class HTMLResourceHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    let parent: String
    let main: String
    private let queue = DispatchQueue(label: "RunBo.html-resources", qos: .userInitiated)
    private var pending: Set<ObjectIdentifier> = [] // Accessed on main only.
    private var totalBytes = 0 // Accessed on the serial resource queue only.
    init(root: URL, parent: String, main: String) { self.root = root; self.parent = parent; self.main = main }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        pending.insert(id)
        let request = urlSchemeTask.request
        queue.async {
            let result = Result { () -> (URLResponse, Data) in
                guard request.httpMethod == "GET", let url = request.url else { throw FileBrowserError("不允许表单或下载。") }
                let path = try BrowserHTMLPolicy.resourcePath(url)
                guard let mime = BrowserHTMLPolicy.mimeType(path, main: self.main) else { throw FileBrowserError("此 HTML 资源类型不允许加载。") }
                let relative = self.parent.isEmpty ? path : self.parent + "/" + path
                let read = try BrowserFileSystem.read(root: self.root, relative: relative)
                guard !read.truncated else { throw FileBrowserError("HTML 或本地资源超过 1 MB，未加载。") }
                self.totalBytes += read.data.count
                guard self.totalBytes <= 16 * BrowserFileSystem.textLimit else { throw FileBrowserError("HTML 本地资源总量超过 16 MB，已停止加载。") }
                var data = read.data
                if path == self.main {
                    let text = try BrowserText.decode(data, truncated: false)
                    data = Data(("<meta http-equiv=\"Content-Security-Policy\" content=\"\(BrowserHTMLPolicy.csp)\"><meta name=\"referrer\" content=\"no-referrer\">" + text.text + ScrollbarStyle.htmlStyle).utf8)
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
                    "Content-Security-Policy": BrowserHTMLPolicy.csp,
                    "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
                ])!
                return (response, data)
            }
            DispatchQueue.main.async {
                guard self.pending.remove(id) != nil else { return }
                switch result {
                case .success(let (response, data)):
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                case .failure(let error): urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { pending.remove(ObjectIdentifier(urlSchemeTask)) }
}
