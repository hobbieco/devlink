import SwiftUI

/// 환경 색 팔레트. 흰 글자 기준 명암비 4.5:1 이상 (탭 배경으로 쓴다).
/// 모든 환경이 자유롭게 고른다 (중복 허용). 새 환경은 이 순서대로 기본값 (환경 개수 번째 색).
enum EnvPalette: String, CaseIterable, Hashable {
    case slate, green, mustard, red, orange, blue, purple, teal, pink, navy

    var color: Color { Color(hex: hexValue) }

    /// HTML 화면에 넘기는 색 (#RRGGBB)
    var hex: String { String(format: "#%06X", hexValue) }

    private var hexValue: UInt32 {
        switch self {
        case .slate: 0x5A6270
        case .green: 0x2E7D46
        case .mustard: 0x85700F
        case .red: 0xB83A3A
        case .orange: 0xA8561A
        case .blue: 0x2F5FB3
        case .purple: 0x6A45A8
        case .teal: 0x1F7A7A
        case .pink: 0xA23C7A
        case .navy: 0x3B4A9E
        }
    }

    /// 환경 없는 탭 (새 탭, 프로젝트 목록 등)
    static let noEnv: EnvPalette = .slate

    /// 새 환경 기본 색: 순서대로 (n 번째 환경 → n 번째 색, 넘치면 처음부터)
    static func defaultColor(forIndex index: Int) -> EnvPalette { allCases[index % allCases.count] }

    /// 예전 데이터: 색을 저장하지 않던 표준 환경 이름의 색 (대소문자 무시)
    static func legacy(forEnvName name: String) -> EnvPalette? {
        switch name.lowercased() {
        case "local": .slate
        case "dev": .green
        case "stg": .mustard
        case "prd": .red
        default: nil
        }
    }

    /// 예전 표준 환경 이름 (이전할 때 한 번 대문자로 바꾼다)
    static let legacyEnvNames = ["local", "dev", "stg", "prd"]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
