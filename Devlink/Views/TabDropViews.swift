import SwiftUI
import UniformTypeIdentifiers

/// 탭 위에 드롭: 같은 화면이면 지나가는 동안 바로 순서 변경, 다른 화면이면 놓은 자리에 삽입.
struct TabItemDropDelegate: DropDelegate {
    let state: WindowState
    let drag: TabDragState
    let pane: Pane
    let target: BrowserTab

    func validateDrop(info: DropInfo) -> Bool { drag.isDragging && info.hasItemsConforming(to: [.devlinkTab]) }

    func dropEntered(info: DropInfo) {
        guard let dragged = drag.tabID, pane.tabs.contains(where: { $0.id == dragged }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { state.reorder(dragged, to: target.id, in: pane) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.tabID else { return false }
        if !pane.tabs.contains(where: { $0.id == dragged }) {
            let index = pane.tabs.firstIndex { $0.id == target.id }
            withAnimation(.easeOut(duration: 0.15)) { state.move(dragged, to: pane, at: index) }
        }
        drag.end()
        return true
    }
}

/// 탭 바 빈 곳에 드롭: 다른 화면의 탭이면 맨 뒤에 추가.
struct TabBarDropDelegate: DropDelegate {
    let state: WindowState
    let drag: TabDragState
    let pane: Pane

    func validateDrop(info: DropInfo) -> Bool { drag.isDragging && info.hasItemsConforming(to: [.devlinkTab]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.tabID else { return false }
        withAnimation(.easeOut(duration: 0.15)) { state.move(dragged, to: pane) }
        drag.end()
        return true
    }
}

/// 탭 드래그 중에만 화면(탭 바 아래 전체)을 덮는 드롭 영역. 웹 영역·주소창이 드롭을 받지 않게 막는다.
struct ContentDropOverlay: View {
    let state: WindowState
    let drag: TabDragState
    let pane: Pane
    @State private var targeted = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.001)   // 드롭을 받기 위한 투명 면
                if targeted, let dragged = drag.tabID, state.canDropOnContent(of: pane, dragged: dragged) {
                    // 분할 전: 새 화면이 생길 오른쪽 절반 / 분할 중: 이 화면 전체
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.15))
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .frame(width: state.isSplit ? geo.size.width : geo.size.width / 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
        .onDrop(of: [.devlinkTab], delegate: Delegate(state: state, drag: drag, pane: pane, targeted: $targeted))
    }

    private struct Delegate: DropDelegate {
        let state: WindowState
        let drag: TabDragState
        let pane: Pane
        @Binding var targeted: Bool

        func validateDrop(info: DropInfo) -> Bool {
            guard let dragged = drag.tabID else { return false }
            return state.canDropOnContent(of: pane, dragged: dragged)
        }
        func dropEntered(info: DropInfo) { targeted = true }
        func dropExited(info: DropInfo) { targeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let dragged = drag.tabID, state.canDropOnContent(of: pane, dragged: dragged) else {
                return DropProposal(operation: .forbidden)
            }
            return DropProposal(operation: .move)
        }
        func performDrop(info: DropInfo) -> Bool {
            targeted = false
            guard let dragged = drag.tabID else { return false }
            withAnimation(.easeOut(duration: 0.2)) { state.dropOnContent(of: pane, dragged: dragged) }
            drag.end()
            return true
        }
    }
}
