import SwiftUI

/// ① titlebar/toolbar · ③ sidebar · panes (② tabs, ⑤ browsing tools, ④ web view, ⑥ dev tools)
struct MainView: View {
    @State private var state = WindowState()
    private let titlebarHeight: CGFloat = 40
    @State private var detailFrame: CGRect = .zero
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            Group {
            // 한 화면일 때와 분할일 때 같은 구조를 쓴다: 분할해도 왼쪽 화면(웹뷰 포함)이 새로 만들어지지 않는다
            if let first = state.panes.first {
                PaneSplitView(ratio: $state.splitRatio, isSplit: state.panes.count == 2) {
                    PaneView(state: state, pane: first)
                } right: {
                    if state.panes.count == 2 { PaneView(state: state, pane: state.panes[1]) }
                }
                .coordinateSpace(name: "paneSplit")
            }
            }
            .frame(minWidth: 850)   // 탭을 쓰는 공간은 850 아래로 줄지 않는다 (창 최소 폭 = 사이드바 + 850)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { detailFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in detailFrame = f }
            })
        }
        .overlay(alignment: .topLeading) {
            // 제목표시줄: | 앱 이름 (사이드바 칸) | 프로젝트·환경 (화면별 가운데) | 버튼 |
            ZStack(alignment: .topLeading) {
                if columnVisibility != .detailOnly {
                    Text("devlink")
                        .font(UIMetrics.titleFont.weight(.semibold))
                        .frame(height: titlebarHeight)
                        .offset(x: 82)
                        .allowsHitTesting(false)
                }
                TitleEnvBar(state: state)
                    .frame(width: detailFrame.width, height: titlebarHeight)
                    .offset(x: detailFrame.minX)
            }
            .offset(y: detailFrame.minY - titlebarHeight)
            .ignoresSafeArea()
        }
        .toolbar {
            // 제목을 숨긴 뒤 버튼을 오른쪽으로 보내기 위한 빈 가운데 항목. 유리 배경이 세로선처럼 보이지 않게 숨김.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                .sharedBackgroundVisibility(.hidden)
            if state.isSplit {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $state.scrollSync) {
                        Label("Scroll Sync", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    .help(state.scrollSync ? String(localized: "Stop scroll sync") : String(localized: "Sync scrolling of the left and right panes"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.toggleSplit()
                } label: {
                    Label(state.isSplit ? String(localized: "Unsplit") : String(localized: "Split View"),
                          systemImage: state.isSplit ? "rectangle" : "rectangle.split.2x1")
                }
                .help(state.isSplit ? String(localized: "Unsplit") : String(localized: "Split View"))
            }
        }
        .navigationTitle(state.windowTitle)
        .toolbar(removing: .title)
        .focusedSceneValue(\.windowState, state)
        .background(WindowCloseGuard(state: state))
        .frame(minHeight: 600)
    }
}
