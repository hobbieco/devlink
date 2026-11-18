import AppKit
import UniformTypeIdentifiers

/// 다른 브라우저로 열기: 설치된 브라우저 목록을 마우스 위치에 메뉴로 띄우고, 고른 브라우저로 주소를 연다.
enum ExternalBrowser {
    /// 메뉴가 닫힌 뒤에 동작이 전달될 수 있어서 잡아 둔다
    private static var handler: Handler?

    /// https 주소와 HTML 파일을 모두 열 수 있는 앱 (기본 브라우저가 맨 위, 이 앱은 제외, 같은 앱은 한 번만).
    /// https 만 보면 브라우저가 아닌 앱(채팅 앱·업데이트 도우미 등)이 섞인다.
    static func apps() -> [URL] {
        let probe = URL(string: "https://example.com")!
        let own = Bundle.main.bundleURL.standardizedFileURL
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: .html).map(\.standardizedFileURL))
        var seen = Set<String>()
        var list = NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { app in
            app.standardizedFileURL != own && html.contains(app.standardizedFileURL)
                && seen.insert(Bundle(url: app)?.bundleIdentifier ?? app.path).inserted
        }
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: probe), let i = list.firstIndex(of: preferred) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }

    static func showMenu(for url: URL) {
        let handler = Handler(url: url)
        Self.handler = handler
        let menu = NSMenu()
        for app in apps() {
            let path = app.path(percentEncoded: false)
            var name = FileManager.default.displayName(atPath: path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            let item = NSMenuItem(title: name, action: #selector(Handler.open(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.preferredImageVisibility = .visible   // macOS 27 부터 메뉴 항목 아이콘은 기본으로 숨겨진다
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No browsers found"), action: nil, keyEquivalent: ""))
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Handler: NSObject {
        let url: URL
        init(url: URL) { self.url = url }

        @objc func open(_ sender: NSMenuItem) {
            guard let app = sender.representedObject as? URL else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
