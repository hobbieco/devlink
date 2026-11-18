import SwiftUI
import WebKit

/// 새 탭 화면 (HTML): 프로젝트 목록 → 프로젝트 화면 → 설정 화면
struct StartPageView: View {
    let state: WindowState
    let tab: BrowserTab
    let route: StartRoute

    var body: some View {
        InternalPageView(state: state, tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// devlink:// 내부 화면 (HTML). 탭마다 WebView 하나.
struct InternalPageView: View {
    let state: WindowState
    let tab: BrowserTab

    var body: some View {
        let session = state.internalSession(for: tab)
        WebViewHost(webView: session.webView, zoom: 1)
            .id("\(tab.id)/\(session.page)")
    }
}
