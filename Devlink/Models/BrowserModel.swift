import SwiftUI
import WebKit

// MARK: - Tabs / Panes / Window

enum StartRoute: Hashable {
    case projects
    case project(UUID)
    /// 프로젝트 설정 화면 (‹ 는 항상 프로젝트 화면으로)
    case settings(UUID)
}

enum TabContent: Hashable {
    case start(StartRoute)
    /// A browsing tab. Env is fixed for the tab's lifetime (최초 환경).
    case page(projectID: UUID, envID: UUID, path: String)
}

@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    /// 탭 묶음: 쿠키·저장소를 함께 쓰는 탭들 (탭에서 파생된 탭은 연 탭의 묶음). 혼자인 탭은 자기 id.
    var groupID: UUID
    var content: TabContent
    /// 현재 주소. 링크·주소창 이동으로 다른 환경/외부로 바뀔 수 있다 (환경 표시는 그대로).
    var currentURL: URL?
    /// 홈 버튼 이동 주소: 이 탭에서 처음 연 링크
    var homeURL: URL?
    /// HTML <title>. 로드 전에는 nil (경로로 대신 표시).
    var pageTitle: String?
    var zoom: Double = 1.0
    /// 모바일 보기: iPhone User-Agent + 페이지 폭(px). nil 이면 끔.
    var mobileWidth: CGFloat?
    /// 직접 고른 User-Agent. nil 이면 기본값 (모바일 보기 중에는 iPhone).
    var userAgent: UserAgentPreset?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    /// 마우스를 올린 링크 (상태 표시줄)
    var hoverURL = ""
    /// 새 탭 화면이 보낸 설명 (상태 표시줄, 마우스를 올린 동안)
    var statusMessage = ""
    var cookieCount = 0
    /// 상태 표시줄 알림 (스크린샷 진행·결과, 다운로드). 캡처 중이면 isCapturing.
    var notice: String?
    var isCapturing = false
    /// 알림을 상태 표시줄에 6초 동안 보인다 (그 사이 다른 알림이 오면 그대로 둔다)
    func showNotice(_ message: String) {
        notice = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.notice == message { self?.notice = nil }
        }
    }
    /// 영역 스크린샷의 위·아래 선을 고르는 중
    var isSelectingArea = false
    /// 룰러 모드 (켜면 페이지에 룰러와 안내선). 안내선(문서 좌표)은 탭이 닫히면 사라진다.
    var isRulerOn = false
    var guideColor = AppSettings.guideColor
    @ObservationIgnored var guidesX: [Double] = []
    @ObservationIgnored var guidesY: [Double] = []
    /// 마지막 로드 실패 메시지 (접속 불가 등). 다음 이동을 시작하면 지운다.
    var loadError: String?
    /// 웹 페이지 탭의 WKWebView. 처음 화면에 보일 때 만든다.
    @ObservationIgnored var session: WebSession?
    /// 새 탭(프로젝트 목록) 내부 화면 WebView
    @ObservationIgnored var internalSession: InternalPageSession?
    /// 프로젝트 목록 검색어 (상세·설정 화면에 다녀와도 유지, 탭 단위)
    var searchText = ""
    /// 프로젝트 화면을 열 때 먼저 보여줄 환경 (카드의 환경 칩·+N)
    var focusEnvID: UUID?
    /// 설정 화면이 알려 준 "저장 안 한 변경 있음"
    var settingsDirty = false

    /// 설정 화면에 저장 안 한 변경이 있는 탭 (닫기 전에 확인한다)
    var hasUnsavedSettings: Bool {
        if case .start(.settings) = content { return settingsDirty }
        return false
    }

    init(content: TabContent = .start(.projects), url: URL? = nil) {
        let id = UUID()
        self.id = id
        self.groupID = id
        self.content = content
        self.currentURL = url
        self.homeURL = url
    }
}

/// 탭 줄·탭 목록에 보이는 묶음 하나 (혼자인 탭은 1개짜리)
struct TabGroup: Identifiable {
    let id: UUID
    var tabs: [BrowserTab]
}

/// User-Agent 프리셋 (렌더링 엔진은 그대로 WebKit 이다)
/// 선 색 (룰러 안내선·영역 스크린샷). 기본값은 설정(AppSettings)에서 고르고, 안내선은 탭마다 따로 바꿀 수 있다 (저장하지 않는다).
enum GuideColor: String, CaseIterable, Identifiable {
    case red, blue, yellow, lime, purple
    var id: Self { self }
    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .blue: String(localized: "Blue")
        case .yellow: String(localized: "Yellow")
        case .lime: String(localized: "Lime")
        case .purple: String(localized: "Purple")
        }
    }
    var hex: String {
        switch self {
        case .red: "#ff3b30"
        case .blue: "#0a84ff"
        case .yellow: "#ffd60a"
        case .lime: "#3ce05a"
        case .purple: "#6a1b9a"
        }
    }
    /// 메뉴에 쓰는 색 견본 (원형, 가장자리선, 선택된 색은 가운데에 점). 색이 유지되도록 템플릿 이미지가 아니다.
    func swatch(selected: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor(hex: self.hex).setFill(); circle.fill()
            NSColor.gray.withAlphaComponent(0.8).setStroke(); circle.lineWidth = 1; circle.stroke()
            if selected {
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5))
                (self == .lime || self == .yellow ? NSColor.black : NSColor.white).setFill(); dot.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

}

enum UserAgentPreset: String, CaseIterable, Identifiable {
    case safariIPhone = "Safari iPhone"
    case chromeMac = "Chrome macOS"
    case chromeAndroid = "Chrome Android"
    case firefoxMac = "Firefox macOS"
    var id: String { rawValue }
    var string: String {
        switch self {
        case .safariIPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .chromeMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        case .chromeAndroid: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
        case .firefoxMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0"
        }
    }
}

/// 모바일 보기 기기 프리셋 (폭만 쓴다)
enum MobileDevice: String, CaseIterable, Identifiable {
    case se = "iPhone SE"
    case standard = "iPhone 16"
    case proMax = "iPhone 16 Pro Max"
    var id: String { rawValue }
    var width: CGFloat {
        switch self {
        case .se: 375
        case .standard: 393
        case .proMax: 440
        }
    }
}

@Observable
final class Pane: Identifiable {
    let id = UUID()
    var tabs: [BrowserTab]
    var selectedTabID: UUID?

    init(tab: BrowserTab = BrowserTab()) {
        tabs = [tab]
        selectedTabID = tab.id
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    var hasPageTabs: Bool {
        tabs.contains { if case .page = $0.content { true } else { false } }
    }

    func add(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func addTab() { add(BrowserTab()) }

    /// 묶음 단위로 나눈 탭 (같은 묶음은 항상 붙어 있다)
    var groups: [TabGroup] {
        var out: [TabGroup] = []
        for tab in tabs {
            if let last = out.last, last.id == tab.groupID { out[out.count - 1].tabs.append(tab) }
            else { out.append(TabGroup(id: tab.groupID, tabs: [tab])) }
        }
        return out
    }

    /// 활성 탭(묶음이면 그 묶음) 바로 오른쪽에 넣고 선택 (사이드바 더블클릭 등)
    func insertAfterSelected(_ tab: BrowserTab) {
        let group = selectedTab?.groupID
        let idx = tabs.lastIndex { $0.groupID == group }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: idx)
        selectedTabID = tab.id
    }

    /// 파생 탭: 연 탭과 같은 묶음의 맨 끝에 넣고 선택
    func addDerived(_ tab: BrowserTab, from opener: BrowserTab) {
        tab.groupID = opener.groupID
        let idx = tabs.lastIndex { $0.groupID == opener.groupID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: idx)
        selectedTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: idx)
        if tabs.isEmpty {
            addTab()
        } else if selectedTabID == id {
            // 묶음 안이면 같은 묶음의 앞 탭으로 (파생 탭을 닫으면 연 탭 쪽), 아니면 그 자리 탭
            if idx > 0, tabs[idx - 1].groupID == closed.groupID { selectedTabID = tabs[idx - 1].id }
            else { selectedTabID = tabs[min(idx, tabs.count - 1)].id }
        }
    }
}

@Observable
final class WindowState {
    /// 앱 전체 공용 프로젝트 목록 (ProjectLibrary)
    var projects: [Project] {
        get { ProjectLibrary.shared.projects }
        set { ProjectLibrary.shared.projects = newValue }
    }
    var panes: [Pane] = [Pane()]
    var focusedPaneID: UUID?
    let drag = TabDragState()
    /// 왼쪽 화면 폭 비율. 분할할 때마다 5:5 로 시작.
    var splitRatio: CGFloat = 0.5
    /// 좌우 화면 스크롤 연동 (분할 상태에서만 의미). WKWebView 연결 후 실제 동작.
    var scrollSync = false

    /// 열린 창 전체 (프로젝트 삭제 때 모든 창의 탭을 닫기 위해)
    @ObservationIgnored static let all = NSHashTable<WindowState>.weakObjects()
    /// 이 상태를 보여주는 창 (닫기 확인용)
    @ObservationIgnored weak var window: NSWindow?

    /// 저장 안 한 설정 화면 탭 수 (창 닫기·종료 확인에 쓴다)
    var unsavedSettingsCount: Int { panes.flatMap(\.tabs).filter(\.hasUnsavedSettings).count }

    /// 탭 닫기 (×, ⌘W, 탭 목록): 저장 안 한 설정이 있으면 확인한다.
    func closeTab(_ id: UUID, in pane: Pane) {
        if let tab = pane.tabs.first(where: { $0.id == id }), tab.hasUnsavedSettings,
           !ConfirmDialogs.confirmDiscardSettings(count: 1) { return }
        pane.closeTab(id)
    }

    /// 웹 페이지 탭 수 (창 닫기·종료 확인에 쓴다)
    var pageTabCount: Int {
        panes.flatMap(\.tabs).filter { if case .page = $0.content { true } else { false } }.count
    }

    init() {
        Self.all.add(self)
        focusedPaneID = panes.first?.id
        if ProcessInfo.processInfo.environment["DEVLINK_DEMO"] != nil { loadDemo() }
    }

    var isSplit: Bool { panes.count > 1 }
    var focusedPane: Pane? { panes.first { $0.id == focusedPaneID } ?? panes.first }

    // MARK: Split

    /// 툴바/메뉴: 왼쪽 기준. 분할이면 항상 오른쪽을 닫고, 아니면 오른쪽에 새 탭으로 분할.
    func toggleSplit() {
        if isSplit {
            if let right = panes.last { closePane(right) }
        } else {
            split()
        }
    }

    @discardableResult
    func split() -> Pane {
        let pane = Pane()
        panes.append(pane)
        focusedPaneID = pane.id
        splitRatio = 0.5
        scrollSync = false
        return pane
    }

    /// 화면 닫기: 그 화면의 탭도 함께 닫는다. 웹 페이지 탭이 있으면 확인 (다시 묻지 않기 가능).
    func closePane(_ pane: Pane) {
        guard isSplit else { return }
        if !ConfirmDialogs.confirmDiscardSettings(count: pane.tabs.filter(\.hasUnsavedSettings).count) { return }
        if pane.hasPageTabs && !ConfirmDialogs.confirmClosePane(tabCount: pane.tabs.count) { return }
        panes.removeAll { $0.id == pane.id }
        focusedPaneID = panes.first?.id
        scrollSync = false
    }

    func otherPane(than pane: Pane) -> Pane? { panes.first { $0.id != pane.id } }

    // MARK: Opening tabs

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    func env(_ projectID: UUID, _ envID: UUID) -> (Project, ProjectEnv)? {
        guard let p = project(projectID), let e = p.envs.first(where: { $0.id == envID }) else { return nil }
        return (p, e)
    }

    /// domain 이 없으면 환경의 홈 도메인
    func makePageTab(project: Project, env: ProjectEnv, domain: EnvDomain? = nil, path: String) -> BrowserTab {
        BrowserTab(content: .page(projectID: project.id, envID: env.id, path: path),
                   url: project.url(env, domain: domain, path: path))
    }

    /// 사이드바 더블클릭: 활성 탭 바로 뒤에 새 독립 탭.
    func openInNewTab(project: Project, env: ProjectEnv, domain: EnvDomain? = nil, path: String = "/") {
        focusedPane?.insertAfterSelected(makePageTab(project: project, env: env, domain: domain, path: path))
    }

    /// 활성 탭이 웹 페이지일 때만 (사이드바 "그룹 탭으로 열기")
    var canOpenInGroup: Bool {
        guard let tab = focusedPane?.selectedTab, case .page = tab.content else { return false }
        return tab.session != nil
    }

    /// 사이드바 우클릭 "그룹 탭으로 열기": 활성 탭의 묶음 맨 끝에, 같은 저장소(쿠키 등)로 연다.
    func openInGroupTab(project: Project, env: ProjectEnv, domain: EnvDomain? = nil, path: String = "/") {
        guard let pane = focusedPane, let opener = pane.selectedTab, case .page = opener.content,
              let parent = opener.session else { return }
        let tab = makePageTab(project: project, env: env, domain: domain, path: path)
        let session = WebSession(tab: tab, store: parent.store)
        attach(session, to: tab)
        if let url = tab.currentURL { session.load(url) }
        pane.addDerived(tab, from: opener)
    }

    /// 사이드바 프로젝트 더블클릭: 프로젝트 화면을 활성 탭 바로 뒤에.
    func openProjectPage(_ project: Project) {
        focusedPane?.insertAfterSelected(BrowserTab(content: .start(.project(project.id))))
    }

    /// 다른 환경으로 대조: 같은 경로를 반대쪽 화면에 새 탭으로 (분할 아니면 분할).
    func openCompare(from tab: BrowserTab, in pane: Pane, env target: ProjectEnv) {
        guard case .page(let pid, let eid, let path) = tab.content, let (project, source) = env(pid, eid) else { return }
        var comparePath = path
        var targetDomain: EnvDomain?
        if let url = tab.currentURL, url.isFileURL {
            comparePath = url.absoluteString   // 파일은 환경과 무관: 같은 파일을 연다
        } else if let url = tab.currentURL {
            comparePath = url.path().isEmpty ? "/" : url.path()
            if let q = url.query() { comparePath += "?\(q)" }
            // 같은 서비스: 원본 환경에서 몇 번째 도메인인지로 대상 환경 도메인을 고른다
            if let key = Self.hostKey(url),
               let i = source.domains.firstIndex(where: { project.host($0).lowercased() == key }),
               i < target.domains.count {
                targetDomain = target.domains[i]
            }
        }
        let dest = otherPane(than: pane) ?? split()
        dest.add(makePageTab(project: project, env: target, domain: targetDomain, path: comparePath))
        focusedPaneID = dest.id
    }

    // MARK: Display

    func title(of tab: BrowserTab) -> String {
        switch tab.content {
        case .start(.projects): return String(localized: "New Tab")
        case .start(.project(let id)): return project(id)?.name ?? String(localized: "New Tab")
        case .start(.settings(let id)): return String(localized: "\(project(id)?.name ?? "") Settings")
        case .page(_, _, let path):
            if let t = tab.pageTitle, !t.isEmpty { return t }
            let p = tab.currentURL?.path() ?? path
            return p.isEmpty ? "/" : p
        }
    }

    /// 탭의 최초 프로젝트·환경 ("프로젝트 · 환경"). 새 탭은 nil.
    func envLabel(of tab: BrowserTab) -> (text: String, color: Color)? {
        guard case .page(let pid, let eid, _) = tab.content, let (p, e) = env(pid, eid) else { return nil }
        return ("\(p.name) · \(e.name)", e.color)
    }

    /// 창 이름 (윈도우 메뉴, Mission Control): 활성 탭의 페이지 제목.
    var windowTitle: String {
        guard let tab = focusedPane?.selectedTab else { return "devlink" }
        return title(of: tab)
    }

    /// 보기 메뉴 "다른 환경으로 대조" 대상: 활성 탭 프로젝트의 다른 환경들.
    var compareTargets: [ProjectEnv] {
        guard let tab = focusedPane?.selectedTab,
              case .page(let pid, let eid, _) = tab.content, let p = project(pid) else { return [] }
        return p.envs.filter { $0.id != eid }
    }

    func compareActiveTab(with env: ProjectEnv) {
        guard let pane = focusedPane, let tab = pane.selectedTab else { return }
        openCompare(from: tab, in: pane, env: env)
    }

    /// 프로젝트 색 (탭 아래 띠). 프로젝트 화면·설정 화면도 그 프로젝트 색. 없으면 nil = 띠 없음.
    func projectColor(of tab: BrowserTab) -> Color? {
        switch tab.content {
        case .page(let pid, _, _), .start(.project(let pid)), .start(.settings(let pid)): project(pid)?.colorValue
        case .start(.projects): nil
        }
    }

    func envColor(of tab: BrowserTab) -> Color? {
        if case .page(let pid, let eid, _) = tab.content { return env(pid, eid)?.1.color }
        return nil
    }
}

// MARK: - Web

extension WindowState {
    /// 탭의 WebSession (없으면 만든다). 저장소는 탭(묶음)마다 따로, 메모리에만.
    func session(for tab: BrowserTab) -> WebSession? {
        if let s = tab.session { return s }
        guard case .page = tab.content else { return nil }
        let session = WebSession(tab: tab, store: DataStores.make())
        attach(session, to: tab)
        if let url = tab.currentURL { session.load(url) }
        return session
    }

    private func attach(_ session: WebSession, to tab: BrowserTab) {
        session.onScroll = { [weak self, weak tab] x, y in
            guard let self, let tab else { return }
            self.syncScroll(from: tab, x: x, y: y)
        }
        session.webView.onMouseDown = { [weak self, weak tab] in
            guard let self, let tab, let pane = self.pane(containing: tab.id) else { return }
            self.focusedPaneID = pane.id
        }
        session.webView.linkURL = { [weak tab] in tab.flatMap { URL(string: $0.hoverURL) } }
        session.webView.onOpenLinkInTab = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.openIndependent(from: tab, url: url)
        }
        session.onOpenWindow = { [weak self, weak tab] configuration, url in
            guard let self, let tab else { return nil }
            return self.openDerived(from: tab, url: url, configuration: configuration)
        }
        session.onLoginFocus = { [weak self, weak tab] rect in
            guard let self, let tab, let rect else { AccountPicker.shared.hide(); return }
            self.showAccounts(for: tab, at: rect)
        }
        session.onClose = { [weak self, weak tab] in
            guard let self, let tab, let pane = self.pane(containing: tab.id) else { return }
            pane.closeTab(tab.id)
        }
        tab.session = session
    }

    /// 로그인 칸에 포커스: 탭 환경에서 지금 주소의 도메인에 등록한 계정 목록을 칸 아래에 띄운다.
    /// 고르면 아이디(와 저장한 비밀번호)를 채운다. 등록한 도메인이 아니거나 계정이 없으면 아무것도 하지 않는다.
    func showAccounts(for tab: BrowserTab, at rect: CGRect) {
        guard case .page(let pid, let eid, _) = tab.content, let (project, env) = env(pid, eid),
              let key = tab.currentURL.flatMap(Self.hostKey),
              let domain = env.domains.first(where: { project.host($0).lowercased() == key }),
              let session = tab.session else { return }
        let accounts = domain.accounts.filter { !$0.login.isEmpty && $0.enabled }
        guard !accounts.isEmpty else { return }
        let items = accounts.map {
            AccountPicker.Item(id: $0.login, name: $0.name, hasPassword: PasswordStore.shared.has(domain: domain.id, account: $0.login))
        }
        AccountPicker.shared.show(items, cssRect: rect, in: session.webView) { [weak session] id in
            session?.fillLogin(id: id, password: PasswordStore.shared.password(domain: domain.id, account: id))
        }
    }

    /// 탭에서 파생된 탭 (페이지가 연 새 창, 링크 ⌘클릭): 연 탭과 같은 묶음·같은 저장소·같은 환경.
    /// configuration 은 WebKit 이 새 창용으로 준 설정 (그대로 써야 window.opener 가 이어지고, 주소도 WebKit 이 연다).
    @discardableResult
    func openDerived(from opener: BrowserTab, url: URL?, configuration: WKWebViewConfiguration? = nil) -> WKWebView? {
        guard let pane = pane(containing: opener.id), case .page(let pid, let eid, _) = opener.content,
              let parent = opener.session else { return nil }
        let tab = BrowserTab(content: .page(projectID: pid, envID: eid, path: url?.path() ?? "/"), url: url)
        let session = WebSession(tab: tab, store: parent.store, configuration: configuration)
        attach(session, to: tab)
        if configuration == nil, let url { session.load(url) }
        pane.addDerived(tab, from: opener)
        focusedPaneID = pane.id
        return session.webView
    }

    /// 링크 우클릭 "Open Link in Tab": 연 탭의 프로젝트·환경으로, 저장소는 새로 만드는 독립 탭 (연 탭 묶음 바로 뒤).
    func openIndependent(from opener: BrowserTab, url: URL) {
        guard let pane = pane(containing: opener.id), case .page(let pid, let eid, _) = opener.content else { return }
        let tab = BrowserTab(content: .page(projectID: pid, envID: eid, path: url.path()), url: url)
        pane.insertAfterSelected(tab)
        focusedPaneID = pane.id
    }

    // MARK: Internal pages (devlink://)

    func internalSession(for tab: BrowserTab) -> InternalPageSession {
        var page = "newtab"
        switch tab.content {
        case .start(.project(let id)):
            page = "project/\(id.uuidString)" + (tab.focusEnvID.map { "?env=\($0.uuidString)" } ?? "")
        case .start(.settings(let id)):
            page = "project/\(id.uuidString)/settings" + (tab.focusEnvID.map { "?env=\($0.uuidString)" } ?? "")
        default:
            break
        }
        if let s = tab.internalSession, s.page == page { return s }
        let session = InternalPageSession(page: page)
        session.search = { [weak tab] in tab?.searchText ?? "" }
        session.webView.onMouseDown = { [weak self, weak tab] in
            guard let self, let tab, let pane = self.pane(containing: tab.id) else { return }
            self.focusedPaneID = pane.id
        }
        session.onMessage = { [weak self, weak tab] type, body in
            guard let self, let tab else { return }
            self.handleInternal(type, body, from: tab)
        }
        tab.internalSession = session
        return session
    }

    private func handleInternal(_ type: String, _ body: [String: Any], from tab: BrowserTab) {
        func uuid(_ key: String) -> UUID? { (body[key] as? String).flatMap(UUID.init(uuidString:)) }
        // 다른 화면으로 넘어가면 설정 화면의 "저장 안 함" 표시는 끝난다
        if ["openProject", "openSettings", "back", "createProject", "openEnv"].contains(type) { tab.settingsDirty = false }
        switch type {
        case "openProject":
            // 프로젝트 화면 (envID 가 오면 그 환경을 먼저)
            if let id = uuid("projectID"), tab.content != .start(.project(id)) {
                tab.focusEnvID = uuid("envID")
                tab.content = .start(.project(id))
            }
        case "openSettings":
            if let id = uuid("projectID") {
                tab.focusEnvID = uuid("envID")
                tab.content = .start(.settings(id))
            }
        case "saveProject":
            // 설정 화면 저장. 실패하면 화면에 알린다 (화면이 먼저 검사하므로 보통은 성공).
            var passwords: [String: String] = [:]
            guard let pid = uuid("projectID"), let base = project(pid), !base.closed,   // closed 는 수정 불가
                  let data = body["project"] as? [String: Any],
                  let edited = Project(edited: data, base: base, passwords: &passwords),
                  !ProjectLibrary.shared.projects.contains(where: { $0.id != pid && $0.name.lowercased() == edited.name.lowercased() }) else {
                tab.internalSession?.call("saveFailed")
                return
            }
            // 비밀번호 먼저 (프로젝트 저장이 없어진 계정의 비밀번호를 정리하고 화면에 알린다)
            PasswordStore.shared.apply(passwords)
            ProjectLibrary.shared.update(edited)
            tab.internalSession?.call("saved")
        case "dirty":
            tab.settingsDirty = body["dirty"] as? Bool ?? false
        case "exportProject":
            if let pid = uuid("projectID"), let p = project(pid) { ProjectTransfer.export([p]) }
        case "deleteProject":
            if let pid = uuid("projectID") { deleteProject(pid, from: tab) }
        case "setLayout":
            // 프로젝트 화면 보기 (탭형/목록형): 모든 프로젝트 공통으로 기억
            UserDefaults.standard.set(body["layout"] as? String ?? "tabs", forKey: "envLayout")
        case "back":
            tab.focusEnvID = nil
            tab.content = .start(.projects)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
        case "createProject":
            let lib = ProjectLibrary.shared
            let source = (body["mode"] as? String) == "duplicate" ? uuid("sourceID").flatMap(project) : nil
            let created = lib.create(name: body["name"] as? String ?? "", from: source,
                                     domains: body["copyDomains"] as? Bool ?? true,
                                     uris: body["copyURIs"] as? Bool ?? true,
                                     accounts: body["copyAccounts"] as? Bool ?? false)
            // 생성 후 설정 화면으로
            tab.focusEnvID = nil
            tab.content = .start(.settings(created.id))
        case "openEnv":
            // domainID 가 없으면 환경의 홈 도메인, path 없으면 /. parameter 는 JS 가 path 에 붙여서 보낸다.
            guard let pid = uuid("projectID"), let eid = uuid("envID"), let (project, env) = env(pid, eid) else { return }
            let domain = uuid("domainID").flatMap { did in env.domains.first { $0.id == did } }
            let path = body["path"] as? String ?? "/"
            switch body["mode"] as? String {
            case "newTab": focusedPane?.add(makePageTab(project: project, env: env, domain: domain, path: path))
            case "compare": openInRightPane(project: project, env: env, domain: domain, path: path)
            default:
                tab.content = .page(projectID: project.id, envID: env.id, path: path)
                tab.currentURL = project.url(env, domain: domain, path: path)
                tab.homeURL = tab.currentURL
                tab.internalSession = nil
            }
        case "openExternal":
            // 프로젝트 화면의 다른 브라우저로 열기: 설치된 브라우저 메뉴를 띄운다 (주소 조립은 openEnv 와 같다)
            guard let pid = uuid("projectID"), let eid = uuid("envID"), let (project, env) = env(pid, eid) else { return }
            let domain = uuid("domainID").flatMap { did in env.domains.first { $0.id == did } }
            if let url = project.url(env, domain: domain, path: body["path"] as? String ?? "/") {
                ExternalBrowser.showMenu(for: url)
            }
        case "search":
            tab.searchText = body["text"] as? String ?? ""
        case "status":
            tab.statusMessage = body["text"] as? String ?? ""
        case "reorder":
            func ids(_ key: String) -> [UUID] { (body[key] as? [String] ?? []).compactMap(UUID.init(uuidString:)) }
            ProjectLibrary.shared.reorder(pinned: ids("pinned"), others: ids("others"), closed: ids("closed"))
        default:
            break
        }
    }

    /// 프로젝트 삭제 (설정 화면): 확인 후 모든 창에서 그 프로젝트 탭을 닫고, 요청한 탭은 프로젝트 목록으로.
    func deleteProject(_ id: UUID, from tab: BrowserTab) {
        guard let project = project(id), !project.isDefault else { return }
        func uses(_ t: BrowserTab) -> Bool {
            switch t.content {
            case .page(let pid, _, _): pid == id
            case .start(.project(let pid)), .start(.settings(let pid)): pid == id
            case .start(.projects): false
            }
        }
        let windows = Self.all.allObjects
        let others = windows.flatMap { $0.panes.flatMap(\.tabs) }.filter { $0.id != tab.id && uses($0) }
        guard ConfirmDialogs.confirmDeleteProject(name: project.name, closingTabs: others.count) else { return }
        for w in windows {
            for pane in w.panes {
                for t in pane.tabs where t.id != tab.id && uses(t) { pane.closeTab(t.id) }
            }
        }
        tab.focusEnvID = nil
        tab.settingsDirty = false
        tab.content = .start(.projects)
        ProjectLibrary.shared.delete(id)
    }

    /// ⌥클릭 대조: 항상 오른쪽 화면에 (분할이 아니면 분할).
    func openInRightPane(project: Project, env: ProjectEnv, domain: EnvDomain? = nil, path: String = "/") {
        let tab = makePageTab(project: project, env: env, domain: domain, path: path)
        let right: Pane
        if isSplit {
            right = panes[panes.count - 1]
            right.add(tab)
        } else {
            right = Pane(tab: tab)
            panes.append(right)
            splitRatio = 0.5
            scrollSync = false
        }
        focusedPaneID = right.id
    }

    /// 주소창 Enter: 항상 현재 탭(같은 저장소)에서 이동.
    func navigate(_ tab: BrowserTab, to url: URL) {
        tab.currentURL = url
        session(for: tab)?.load(url)
    }

    func goHome(_ tab: BrowserTab) {
        guard let url = tab.homeURL else { return }
        navigate(tab, to: url)
    }

    /// 전체 화면 스크린샷을 다운로드 폴더에 PNG 로 저장. 진행·결과는 상태 표시줄에 보인다.
    func captureFullPage(_ tab: BrowserTab, visibleWidthOnly: Bool = false, area: CGRect? = nil) {
        guard !tab.isCapturing, let session = session(for: tab) else { return }
        tab.isCapturing = true
        tab.notice = String(localized: "Capturing…")
        let title = title(of: tab)
        Task { @MainActor in
            do {
                let result = try await session.captureFullPage(visibleWidthOnly: visibleWidthOnly, area: area)
                let url = Self.screenshotURL(title: title)
                try await Task.detached { try result.data.write(to: url) }.value
                tab.notice = result.truncated
                    ? String(localized: "Saved (cut at max height): \(url.lastPathComponent)")
                    : String(localized: "Saved: \(url.lastPathComponent)")
            } catch {
                tab.notice = String(localized: "Screenshot failed: \(error.localizedDescription)")
            }
            tab.isCapturing = false   // 알림이 떠 있는 동안에도 다시 찍을 수 있다
            let message = tab.notice
            try? await Task.sleep(for: .seconds(6))
            if tab.notice == message { tab.notice = nil }
        }
    }

    /// 룰러 모드 켜기·끄기. 끄면 안내선은 숨기고 기억만 한다.
    func toggleRuler(_ tab: BrowserTab) {
        guard let session = session(for: tab) else { return }
        tab.isRulerOn.toggle()
        if tab.isRulerOn { session.showRulerOverlay() } else { session.hideRulerOverlay() }
    }

    /// 안내선 색 바꾸기 (룰러가 켜져 있으면 바로 다시 그린다)
    func setGuideColor(_ tab: BrowserTab, _ color: GuideColor) {
        tab.guideColor = color
        session(for: tab)?.showRulerOverlay()
    }

    /// 영역 스크린샷: 페이지에 위·아래 선을 띄우고, 확정하면 그 사각형만 저장한다. 선택 중에 다시 누르면 취소.
    func captureArea(_ tab: BrowserTab) {
        guard let session = session(for: tab) else { return }
        if tab.isSelectingArea { session.cancelAreaSelection(); return }
        guard !tab.isCapturing else { return }
        tab.isSelectingArea = true
        session.onAreaSelected = { [weak self, weak tab, weak session] area in
            guard let self, let tab else { return }
            tab.isSelectingArea = false
            session?.onAreaSelected = nil
            if let area { self.captureFullPage(tab, area: area) }
        }
        session.beginAreaSelection()
    }

    /// <스크린샷 저장 폴더>/<제목> yyyy-MM-dd HH.mm.ss.png (파일명에 못 쓰는 글자는 뺀다)
    private static func screenshotURL(title: String) -> URL {
        let folder = AppSettings.screenshotFolder
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Screenshot" }
        if name.count > 60 { name = String(name.prefix(60)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appendingPathComponent("\(name) \(formatter.string(from: Date())).png")
    }

    /// 쿠키·저장소 삭제 (묶음 탭은 저장소를 함께 쓰므로 묶음 전체에 적용된다).
    func clearStorage(_ tab: BrowserTab, _ kind: ClearKind) {
        guard let session = session(for: tab) else { return }
        Task { await session.clear(kind) }
    }

    /// 스크롤 연동: 화면에 보이는 탭끼리만, 반대쪽 화면의 선택 탭에 같은 비율로.
    func syncScroll(from tab: BrowserTab, x: Double, y: Double) {
        guard scrollSync, isSplit, let source = pane(containing: tab.id), source.selectedTabID == tab.id,
              let other = otherPane(than: source), let target = other.selectedTab, target !== tab else { return }
        target.session?.applyScroll(x: x, y: y)
    }
}

// MARK: - Focused value for menu commands

struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
