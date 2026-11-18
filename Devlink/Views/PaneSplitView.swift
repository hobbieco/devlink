import SwiftUI
import AppKit

/// 좌우 분할. 비율은 WindowState.splitRatio (분할 시 0.5로 시작), 구분선 드래그로 조절.
struct PaneSplitView<Left: View, Right: View>: View {
    @Binding var ratio: CGFloat
    var isSplit = true
    var minWidth: CGFloat = 320
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    private let handleWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let leftWidth = isSplit ? clamped(ratio, total: total) * total : total + 0.5
            HStack(spacing: 0) {
                left.frame(width: max(0, leftWidth - 0.5))
                if isSplit {
                    divider(total: total)
                    right.frame(width: max(0, total - leftWidth - 0.5))
                }
            }
            .frame(width: total, alignment: .leading)
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: handleWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("paneSplit"))
                            .onChanged { ratio = clamped($0.location.x / total, total: total) }
                    )
            }
            .onTapGesture(count: 2) { ratio = 0.5 }
    }

    private func clamped(_ value: CGFloat, total: CGFloat) -> CGFloat {
        guard total > minWidth * 2 else { return 0.5 }
        let minRatio = minWidth / total
        return min(1 - minRatio, max(minRatio, value))
    }
}
