import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 앱 내부 탭 드래그 전용 타입 (웹 페이지·텍스트 드롭과 구분)
    static let devlinkTab = UTType(exportedAs: "kr.pe.hobbieco.devlink.tab", conformingTo: .data)
}

/// 탭 드래그 상태. 드래그 중에는 각 화면 위에 드롭 오버레이를 띄워 웹 영역이 드롭을 받지 않게 한다.
@Observable
final class TabDragState {
    var tabID: UUID?
    /// 끌고 있는 탭의 묶음 (묶음째로 움직인다)
    var groupID: UUID?
    var sourcePaneID: UUID?
    /// 이번 드래그에서 묶음을 통째로 옮겼는지
    @ObservationIgnored var movedGroup = false
    private var watcher: Timer?

    var isDragging: Bool { tabID != nil }

    func begin(tab: UUID, group: UUID, pane: UUID) {
        tabID = tab
        groupID = group
        movedGroup = false
        sourcePaneID = pane
        // SwiftUI 드래그는 종료 콜백이 없어서, 마우스 버튼이 떼어지면 끝난 것으로 본다 (드롭·취소·창 밖 모두).
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
            }
        }
    }

    func end() {
        watcher?.invalidate()
        watcher = nil
        tabID = nil
        groupID = nil
        movedGroup = false
        sourcePaneID = nil
    }
}

extension WindowState {
    func pane(_ id: UUID?) -> Pane? { panes.first { $0.id == id } }

    func pane(containing tabID: UUID) -> Pane? { panes.first { $0.tabs.contains { $0.id == tabID } } }

    /// 같은 화면 안 순서 변경. 같은 묶음 안이면 dragged 를 target 자리로,
    /// 다른 묶음이면 dragged 의 묶음 전체를 target 묶음 앞(왼쪽으로 갈 때)·뒤(오른쪽으로 갈 때)로.
    func reorder(_ dragged: UUID, to target: UUID, in pane: Pane) {
        guard dragged != target,
              let from = pane.tabs.firstIndex(where: { $0.id == dragged }),
              let to = pane.tabs.firstIndex(where: { $0.id == target }) else { return }
        let group = pane.tabs[from].groupID
        let targetGroup = pane.tabs[to].groupID
        if group == targetGroup {
            guard !drag.movedGroup else { return }   // 묶음째 옮긴 뒤에는 묶음 안 순서를 건드리지 않는다
            let tab = pane.tabs.remove(at: from)
            pane.tabs.insert(tab, at: to)
            return
        }
        // 대상 묶음을 다 지나갔을 때만 옮긴다 (오른쪽으로 갈 때는 묶음의 마지막 탭, 왼쪽으로 갈 때는 첫 탭 위).
        // 묶음 중간에서 옮기면 폭이 달라 마우스 아래 탭이 바뀌면서 앞뒤로 계속 다시 옮겨진다.
        let edge = from < to ? pane.tabs.lastIndex { $0.groupID == targetGroup } : pane.tabs.firstIndex { $0.groupID == targetGroup }
        guard edge == to else { return }
        let block = pane.tabs.filter { $0.groupID == group }
        pane.tabs.removeAll { $0.groupID == group }
        let anchor = from < to
            ? (pane.tabs.lastIndex { $0.groupID == targetGroup } ?? pane.tabs.count - 1) + 1
            : pane.tabs.firstIndex { $0.groupID == targetGroup } ?? 0
        pane.tabs.insert(contentsOf: block, at: anchor)
        if block.count > 1 { drag.movedGroup = true }
    }

    /// 다른 화면으로 이동 (index 없으면 맨 뒤): 묶음째로. 빠진 쪽이 비면 그 화면을 닫는다.
    func move(_ tabID: UUID, to dest: Pane, at index: Int? = nil) {
        guard let source = pane(containing: tabID), source.id != dest.id,
              let tab = source.tabs.first(where: { $0.id == tabID }),
              let from = source.tabs.firstIndex(where: { $0.groupID == tab.groupID }) else { return }
        let block = source.tabs.filter { $0.groupID == tab.groupID }
        source.tabs.removeAll { $0.groupID == tab.groupID }
        var at = min(index ?? dest.tabs.count, dest.tabs.count)
        // 다른 묶음 사이에는 끼어들지 않는다: 그 묶음 앞으로
        while at > 0, at < dest.tabs.count, dest.tabs[at].groupID == dest.tabs[at - 1].groupID { at -= 1 }
        dest.tabs.insert(contentsOf: block, at: at)
        dest.selectedTabID = tab.id
        focusedPaneID = dest.id
        removeIfEmpty(source, removedIndex: from)
    }

    /// 내용 영역에 드롭 → 분할 (왼쪽 기준: 새 화면은 항상 오른쪽). 묶음째로 옮긴다.
    func splitWith(_ tabID: UUID) {
        guard !isSplit, let source = pane(containing: tabID),
              let tab = source.tabs.first(where: { $0.id == tabID }),
              let from = source.tabs.firstIndex(where: { $0.groupID == tab.groupID }) else { return }
        let block = source.tabs.filter { $0.groupID == tab.groupID }
        guard source.tabs.count > block.count else { return }
        source.tabs.removeAll { $0.groupID == tab.groupID }
        if !source.tabs.contains(where: { $0.id == source.selectedTabID }) {
            source.selectedTabID = source.tabs[min(from, source.tabs.count - 1)].id
        }
        let pane = Pane(tab: tab)
        pane.tabs = block
        panes.append(pane)
        splitRatio = 0.5
        scrollSync = false
        focusedPaneID = pane.id
    }

    /// 드롭 가능 여부: 단일 화면이면 끌고 있는 묶음 말고 다른 탭이 남을 때 분할, 분할이면 반대쪽 화면으로만.
    func canDropOnContent(of target: Pane, dragged: UUID) -> Bool {
        guard let source = pane(containing: dragged),
              let tab = source.tabs.first(where: { $0.id == dragged }) else { return false }
        if isSplit { return source.id != target.id }
        return source.tabs.contains { $0.groupID != tab.groupID }
    }

    func dropOnContent(of target: Pane, dragged: UUID) {
        if isSplit { move(dragged, to: target) } else { splitWith(dragged) }
    }

    private func removeIfEmpty(_ pane: Pane, removedIndex: Int) {
        if pane.tabs.isEmpty {
            panes.removeAll { $0.id == pane.id }
            if panes.isEmpty { panes = [Pane()] }
            scrollSync = false
        } else if !pane.tabs.contains(where: { $0.id == pane.selectedTabID }) {
            pane.selectedTabID = pane.tabs[min(removedIndex, pane.tabs.count - 1)].id
        }
    }
}
