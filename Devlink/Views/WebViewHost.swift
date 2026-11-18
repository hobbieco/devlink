import SwiftUI
import WebKit

/// 탭의 WKWebView 를 화면에 올린다 (탭을 옮겨도 같은 인스턴스라 페이지·저장소 유지).
/// Web Inspector 를 붙이면 WebKit 이 같은 부모 뷰 안에서 웹뷰와 인스펙터의 frame 을 직접 나누므로,
/// SwiftUI 가 웹뷰 크기를 정하지 않도록 frame 기반 컨테이너에 담는다.
/// 모바일 보기 중에는 페이지가 기기 폭으로만 그려지고 왼쪽에 붙으므로, 뷰의 bounds 원점을 옮겨 가운데로 오게 하고
/// 양옆 빈 영역을 회색으로 덮어 구분한다.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let zoom: Double
    var mobileWidth: CGFloat? = nil

    /// 웹뷰마다 컨테이너를 하나만 만들어 계속 쓴다: 탭을 옮길 때 새로 만들면, 컨테이너에 붙어 있던
    /// Web Inspector 화면이 옛 컨테이너에 남아 개발자 도구가 검은 화면이 된다.
    func makeNSView(context: Context) -> WebHostView {
        if let host = (webView as? FocusAwareWebView)?.host as? WebHostView { return host }
        let host = WebHostView(webView: webView)
        (webView as? FocusAwareWebView)?.host = host
        return host
    }

    func updateNSView(_ view: WebHostView, context: Context) {
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        view.mobileWidth = mobileWidth
    }
}

final class WebHostView: NSView {
    private weak var webView: WKWebView?   // 웹뷰가 이 컨테이너를 붙잡고 있으므로 약하게 (순환 방지)
    private let leftCover = CoverView()
    private let rightCover = CoverView()
    var mobileWidth: CGFloat? { didSet { updateCover() } }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        webView.postsFrameChangedNotifications = true
        // 내용을 옮겨도 웹뷰 영역 밖(옆의 인스펙터)으로 그려지지 않게 자른다
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true
        addSubview(webView)
        addSubview(leftCover)
        addSubview(rightCover)
        leftCover.isHidden = true
        rightCover.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(webViewFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: webView)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func webViewFrameChanged() { updateCover() }

    /// 웹뷰 frame 은 WebKit 이 정한 대로 읽기만 하고, 내용 위치(bounds 원점)와 덮개만 맞춘다.
    private func updateCover() {
        guard let webView else { return }
        let frame = webView.frame
        let width = (mobileWidth ?? 0) * webView.pageZoom
        guard mobileWidth != nil, frame.width > width else {
            webView.setBoundsOrigin(.zero)
            leftCover.isHidden = true
            rightCover.isHidden = true
            return
        }
        let margin = ((frame.width - width) / 2).rounded()
        webView.setBoundsOrigin(NSPoint(x: -margin, y: 0))
        leftCover.frame = NSRect(x: frame.minX, y: frame.minY, width: margin, height: frame.height)
        rightCover.frame = NSRect(x: frame.minX + margin + width, y: frame.minY,
                                  width: frame.width - margin - width, height: frame.height)
        leftCover.isHidden = false
        rightCover.isHidden = false
    }
}

/// 회색 덮개. 마우스 동작은 아래 웹뷰로 통과시킨다.
private final class CoverView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
