import SwiftUI

/// 2560×1440 전체 화면 기준 글꼴 크기. depth 와 관계없이 같은 영역은 같은 크기.
enum UIMetrics {
    /// 탭, 탭 목록, 주소창, 사이드바 (모든 depth)
    static let font = Font.system(size: 14)
    /// 상태 표시줄
    static let statusFont = Font.system(size: 12)
    /// 제목표시줄 (앱 이름, 프로젝트·환경)
    static let titleFont = Font.system(size: 14)
    static let statusBarHeight: CGFloat = 26
    /// 활성 탭 배경 밝기 (Color.primary 투명도). 글자는 흰색(기본) 유지.
    static let activeTabFill: Double = 0.28
}
