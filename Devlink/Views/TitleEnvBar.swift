import SwiftUI

/// 앱 제목표시줄의 프로젝트·환경 표시.
/// 분할 아님: 본문 가운데. 분할: 각 화면 폭의 가운데. 포커스된 쪽은 진하게.
/// 표시 전용 (클릭은 제목표시줄 창 끌기에 양보). 대조는 보기 메뉴에서.
struct TitleEnvBar: View {
    let state: WindowState
    /// 오른쪽 툴바 버튼(스크롤 연동, 분할) 자리
    private let trailingReserve: CGFloat = 96
    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            if state.isSplit, state.panes.count == 2 {
                // 각 화면 폭의 가운데. 오른쪽은 툴바 버튼과 겹치지 않게 폭만 줄인다.
                let x = state.splitRatio * width
                HStack(spacing: 0) {
                    label(for: state.panes[0])
                        .frame(maxWidth: max(0, x - 2 * gap))
                        .frame(width: x)
                    label(for: state.panes[1])
                        .frame(maxWidth: max(0, width - x - 2 * trailingReserve))
                        .frame(width: width - x)
                }
                .frame(maxHeight: .infinity)
            } else if let pane = state.panes.first {
                label(for: pane)
                    .frame(maxWidth: max(0, width - trailingReserve * 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func label(for pane: Pane) -> some View {
        let focused = !state.isSplit || state.focusedPaneID == pane.id
        HStack(spacing: 6) {
            if let tab = pane.selectedTab, let env = state.envLabel(of: tab) {
                Circle().fill(env.color).frame(width: 9, height: 9)
                Text(env.text).fontWeight(focused ? .semibold : .regular)
                warning(for: tab)
            } else {
                Text("New Tab")
            }
        }
        .font(UIMetrics.titleFont)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(focused ? .primary : .secondary)
    }

    @ViewBuilder
    private func warning(for tab: BrowserTab) -> some View {
        switch state.visitStatus(of: tab) {
        case .otherEnv: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .external: Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
        case .sameEnv, .unchecked: EmptyView()
        }
    }
}
