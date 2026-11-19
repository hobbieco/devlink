import AppKit
import WebKit

/// 클릭하면 그 화면을 활성(포커스)으로 만들기 위해 mouseDown 을 알려주는 WKWebView.
final class FocusAwareWebView: WKWebView {
    var onMouseDown: (() -> Void)?
    /// 화면에 올릴 때 쓰는 컨테이너 (WebViewHost 가 한 번 만들어 계속 쓴다)
    var host: NSView?
    /// 우클릭한 링크 주소 (마우스를 올린 링크)와 "독립 탭으로 열기" 요청
    var linkURL: (() -> URL?)?
    var onOpenLinkInTab: ((URL) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    /// 우클릭 메뉴: 새 창 항목은 이 앱에서 같은 묶음의 새 탭(그룹 탭)으로 열리므로 이름을 맞추고,
    /// 링크에는 독립 탭으로 여는 항목을 그 아래에 더한다.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for (index, item) in menu.items.enumerated() {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                item.title = String(localized: "Open Link in Group Tab")
                if let url = linkURL?(), ["http", "https", "file"].contains(url.scheme?.lowercased()) {
                    let independent = NSMenuItem(title: String(localized: "Open Link in Tab"),
                                                 action: #selector(openLinkInTab(_:)), keyEquivalent: "")
                    independent.target = self
                    independent.representedObject = url
                    menu.insertItem(independent, at: index + 1)
                }
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = String(localized: "Open Image in New Tab")
            default: break
            }
        }
    }

    @objc private func openLinkInTab(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onOpenLinkInTab?(url) }
    }
}

/// devlink:// 내부 화면. 앱 번들의 HTML/CSS/JS 를 내보낸다.
///   devlink://newtab            → newtab.html
///   devlink://project/<id>?env=<envID> → project.html (프로젝트 화면)
///   devlink://project/<id>/settings    → settings.html (프로젝트 설정)
///   devlink://<name>.css|.js     → 번들 리소스
final class DevlinkSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "devlink"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host() else { return fail(task) }
        let name = host + url.path()
        let resource = switch host {
        case "newtab": "newtab.html"
        case "project": url.path().hasSuffix("/settings") ? "settings.html" : "project.html"
        default: name
        }
        let ext = (resource as NSString).pathExtension
        guard let fileURL = Bundle.main.url(forResource: (resource as NSString).deletingPathExtension, withExtension: ext),
              let data = try? Data(contentsOf: fileURL) else { return fail(task) }
        respond(task, url: url, data: data, mime: Self.mime(for: ext))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mime: String) {
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html"
        case "css": "text/css"
        case "js": "text/javascript"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }
}

/// 내부 화면 탭 하나의 WebView 와 JS ↔ Swift 브리지.
/// 브리지는 내부 화면에만 등록하고, devlink:// 에서 온 메시지만 받는다.
final class InternalPageSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: FocusAwareWebView
    /// 불러온 화면 (newtab, project/<id>?env=…)
    let page: String
    /// JS 요청 처리 (WindowState 가 연결)
    var onMessage: ((String, [String: Any]) -> Void)?
    /// 프로젝트 목록 검색어 (탭이 들고 있음)
    var search: () -> String = { "" }
    private var observer: NSObjectProtocol?

    init(page: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DevlinkSchemeHandler(), forURLScheme: DevlinkSchemeHandler.scheme)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = FocusAwareWebView(frame: .zero, configuration: config)
        self.page = page
        super.init()
        config.userContentController.add(InternalWeakHandler(self), name: "lh")
        config.userContentController.addUserScript(Self.i18nScript)
        webView.navigationDelegate = self
        webView.isInspectable = true
        webView.setValue(false, forKey: "drawsBackground")   // 로드 전 흰 화면 깜빡임 방지
        webView.load(URLRequest(url: URL(string: "\(DevlinkSchemeHandler.scheme)://\(page)")!))
        observer = NotificationCenter.default.addObserver(forName: .devlinkProjectsChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushState() }
        }
    }

    /// 화면 문구 번역: 코드의 영어 원문이 키. 번역표(strings-<언어>.json)가 있으면 그 언어로, 없으면 원문 그대로.
    /// tr("Delete {name}?", { name }) 형태, 고정 글자는 data-i18n(글자) · data-i18n-title · data-i18n-placeholder.
    static let i18nScript: WKUserScript = {
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        var table = "{}"
        if let url = Bundle.main.url(forResource: "strings-\(lang)", withExtension: "json"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            table = text
        }
        let source = """
        window.L = \(table);
        window.tr = function (s, v) {
          var r = (window.L && window.L[s]) || s;
          return v ? r.replace(/\\{(\\w+)\\}/g, function (m, k) { return v[k] !== undefined ? v[k] : m; }) : r;
        };
        document.addEventListener('DOMContentLoaded', function () {
          document.querySelectorAll('[data-i18n]').forEach(function (el) { el.textContent = tr(el.textContent.trim()); });
          document.querySelectorAll('[data-i18n-title]').forEach(function (el) { el.title = tr(el.title); });
          document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) { el.placeholder = tr(el.placeholder); });
          document.title = tr(document.title);
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    deinit {
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "lh")
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.protocol == DevlinkSchemeHandler.scheme,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { pushState() } else { onMessage?(type, body) }
    }

    /// 화면의 devlink.<name>() 호출 (저장 결과 알림 등)
    func call(_ name: String, _ args: [Any] = []) {
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        webView.evaluateJavaScript("window.devlink && devlink.\(name)(...\(json))", completionHandler: nil)
    }

    /// 화면에 현재 프로젝트 목록·정렬을 보낸다.
    func pushState() {
        // 비밀번호 값은 그 프로젝트의 설정 화면에만 보낸다 (project/<id>/settings)
        let parts = page.split(separator: "/")
        let settingsID = parts.count == 3 && parts[2].hasPrefix("settings") ? UUID(uuidString: String(parts[1])) : nil
        let projects: [[String: Any]] = ProjectLibrary.shared.projects.map { p in
            [
                "id": p.id.uuidString,
                "name": p.name,
                "description": p.description ?? "",
                "baseDomain": p.baseDomain,
                "pinned": p.pinned,
                "isDefault": p.isDefault,
                "closed": p.closed,
                "color": p.color ?? "",
                "visitCheck": p.visitCheck,
                // 추가 팝업의 복제 요약
                "summary": [
                    "domain": p.baseDomain,
                    "uris": p.envs.flatMap(\.domains).reduce(0) { $0 + $1.uris.count },
                    "accounts": Set(p.envs.flatMap(\.domains).flatMap(\.accounts).map(\.login)).count,
                ],
                // ready: 열 수 있는 도메인이 있어야 (없으면 카드에서 비활성)
                "envs": p.envs.map { e -> [String: Any] in
                    ["id": e.id.uuidString, "name": e.name, "rawName": e.name, "color": e.palette.hex,
                     "palette": e.palette.rawValue,
                     "ready": p.isReady(e),
                     "domains": e.domains.map { d -> [String: Any] in
                         ["id": d.id.uuidString, "alias": d.alias, "origin": p.origin(d) ?? "",
                          "ssl": d.ssl, "useBase": d.useBase, "sub": d.sub, "showInSidebar": d.showInSidebar, "swaggerAuth": d.swaggerAuth, "tokenPrefix": d.tokenPrefix,
                          "tokenKey": d.tokenKey, "tokenPath": d.tokenPath,
                          "accounts": d.accounts.map { a -> [String: Any] in
                              var out: [String: Any] = ["id": a.login, "name": a.name, "enabled": a.enabled, "http": a.http]
                              if p.id == settingsID, PasswordStore.shared.isLocked(domain: d.id, account: a.login) {
                                  out["locked"] = true   // 값은 보내지 않고 저장돼 있는지만
                                  out["hasPw"] = PasswordStore.shared.has(domain: d.id, account: a.login)
                              }
                              return out
                          },
                          "passwords": p.id == settingsID ? PasswordStore.shared.passwords(domain: d.id, accounts: d.accounts.map(\.login)) : [:],
                          "uris": d.uris.map { u -> [String: Any] in
                              ["id": u.id.uuidString, "alias": u.alias, "path": u.path, "showInSidebar": u.showInSidebar,
                               "params": u.params.map { ["key": $0.key, "value": $0.value, "desc": $0.desc, "enabled": $0.enabled] }]
                          }]
                     }]
                },
            ]
        }
        let state: [String: Any] = ["projects": projects, "search": search(),
                                    // 설정 화면 색 견본 (이 순서가 새 환경 기본 색 순서)
                                    "palettes": EnvPalette.allCases.map { ["key": $0.rawValue, "hex": $0.hex] },
                                    "envLayout": UserDefaults.standard.string(forKey: "envLayout") ?? "tabs",
                                    "authAvailable": Authenticator.available]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.devlink && devlink.render(\(json))", completionHandler: nil)
    }
}

private final class InternalWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: InternalPageSession?
    init(_ target: InternalPageSession) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
