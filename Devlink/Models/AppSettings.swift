import Foundation

/// 앱 전체 설정 (UserDefaults). 설정 창(⌘,)에서 바꾼다. 저장 위치는 비어 있거나 폴더가 없어졌으면 ~/Downloads.
enum AppSettings {
    static let guideColorKey = "guideColor"
    static let captureColorKey = "captureLineColor"
    static let screenshotFolderKey = "screenshotFolder"
    static let downloadFolderKey = "downloadFolder"

    /// 새 탭의 안내선 색 (탭마다 메뉴에서 바꿀 수 있다)
    static var guideColor: GuideColor { color(forKey: guideColorKey, default: .red) }
    /// 영역 스크린샷 선 색의 기본값 (캡처 막대에서 그때그때 바꿀 수 있다)
    static var captureColor: GuideColor { color(forKey: captureColorKey, default: .blue) }
    static var screenshotFolder: URL { folder(forKey: screenshotFolderKey) }
    static var downloadFolder: URL { folder(forKey: downloadFolderKey) }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func color(forKey key: String, default fallback: GuideColor) -> GuideColor {
        GuideColor(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? fallback
    }

    private static func folder(forKey key: String) -> URL {
        if let path = UserDefaults.standard.string(forKey: key), !path.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return defaultFolder
    }

    /// 같은 이름이 있으면 "이름 (2).확장자" 처럼 번호를 붙인다
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let bad = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        var clean = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { clean = "download" }
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var url = folder.appendingPathComponent(clean)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
