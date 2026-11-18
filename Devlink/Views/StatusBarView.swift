import SwiftUI

/// 화면(pane)별 하단 상태 표시줄 (2칸): 메시지(방문 상태·링크·로딩) | 저장소·보기.
/// 프로젝트·환경은 앱 제목표시줄(TitleEnvBar)에 표시.
/// 쿠키 수, 저장소 크기, 링크 URL 은 WKWebView 연결 후 실제 값으로 채운다.
struct StatusBarView: View {
    let state: WindowState
    let pane: Pane
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 12) {
            switch tab.content {
            case .start(let route):
                Text(route == .projects && !tab.statusMessage.isEmpty ? tab.statusMessage : String(localized: "New Tab"))
                    .foregroundStyle(.secondary)
                Spacer()
            case .page(let pid, let eid, _):
                if let (project, _) = state.env(pid, eid) {
                    // 왼쪽: 방문 상태 · 링크 · 로딩 등 메시지 / 오른쪽: 저장소 · 보기
                    visitLabel(ownProject: project.name).layoutPriority(1)
                    linkOrLoading.layoutPriority(-1)
                    Spacer(minLength: 8)
                    storageMenu(project: project)
                    viewInfo
                }
            }
        }
        .font(UIMetrics.statusFont)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: UIMetrics.statusBarHeight)
        .background(.bar)
    }

    @ViewBuilder
    private func visitLabel(ownProject: String) -> some View {
        switch state.visitStatus(of: tab) {
        case .sameEnv, .unchecked:
            EmptyView()
        case .otherEnv(let project, let env):
            Label("Visiting another env: \(project == ownProject ? env : "\(project) · \(env)")",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .external:
            Label("Visiting external: \(tab.currentURL.flatMap(WindowState.hostKey) ?? "")", systemImage: "arrow.up.right.square")
                .foregroundStyle(.secondary)
        }
    }

    private func storageMenu(project: Project) -> some View {
        Menu {
            ClearMenuItems(state: state, tab: tab)
        } label: {
            Text("Cookies \(tab.cookieCount)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Deleted when the tab closes")
    }

    @ViewBuilder
    private var linkOrLoading: some View {
        if let message = tab.notice {
            Text(message).foregroundStyle(.secondary).truncationMode(.middle)
        } else if tab.isLoading {
            Text("Loading \(Int(tab.progress * 100))%").foregroundStyle(.secondary)
        } else if !tab.hoverURL.isEmpty {
            Text(tab.hoverURL).foregroundStyle(.secondary).truncationMode(.middle)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var viewInfo: some View {
        Button("\(Int(tab.zoom * 100))%") { tab.zoom = 1 }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Zoom · click: actual size")
    }
}
