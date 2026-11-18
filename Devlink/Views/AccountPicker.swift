import AppKit
import SwiftUI
import WebKit

/// 로그인 칸 아래에 뜨는 계정 목록 (다른 브라우저의 자동 완성처럼). 계정이 하나여도 목록에서 고른다.
final class AccountPicker {
    static let shared = AccountPicker()
    private var popover: NSPopover?

    struct Item: Identifiable {
        let id: String
        let name: String
        let hasPassword: Bool
        let locked: Bool
    }

    /// cssRect: 입력 칸의 화면(viewport) 좌표 (CSS px)
    func show(_ items: [Item], cssRect: CGRect, in webView: WKWebView, onPick: @escaping (String) -> Void) {
        hide()
        let zoom = webView.pageZoom * webView.magnification
        var rect = CGRect(x: cssRect.minX * zoom, y: cssRect.minY * zoom, width: cssRect.width * zoom, height: cssRect.height * zoom)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        guard webView.window != nil, webView.bounds.intersects(rect) else { return }

        let popover = NSPopover()
        popover.behavior = .transient   // 다른 곳을 누르면 닫힌다
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: AccountList(items: items) { [weak self] id in
            self?.hide()
            onPick(id)
        })
        popover.show(relativeTo: rect, of: webView, preferredEdge: webView.isFlipped ? .maxY : .minY)
        self.popover = popover
    }

    func hide() {
        popover?.close()
        popover = nil
    }
}

private struct AccountList: View {
    let items: [AccountPicker.Item]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in AccountRow(item: item) { onPick(item.id) } }
        }
        .padding(6)
        .frame(width: 260)
    }
}

private struct AccountRow: View {
    let item: AccountPicker.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "person")
                // 이름이 있으면 이름 아래에 아이디
                VStack(alignment: .leading, spacing: 1) {
                    if item.name.isEmpty {
                        Text(item.id).font(UIMetrics.font)
                    } else {
                        Text(item.name).font(UIMetrics.font)
                        Text(item.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                // 비밀번호가 저장된 계정
                if item.locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                else if item.hasPassword { Image(systemName: "key.fill").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.locked ? String(localized: "Locked: authenticate to fill") : item.hasPassword ? String(localized: "Fill ID and password") : String(localized: "Fill ID only (no saved password)"))
    }
}
