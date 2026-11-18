import AppKit
import WebKit

/// 탭 하나의 WKWebView 와 그 상태 동기화. 탭(BrowserTab)이 소유하므로 화면 이동·분할에도 페이지가 유지된다.
final class WebSession: NSObject {
    let webView: FocusAwareWebView
    let store: WKWebsiteDataStore
    weak var tab: BrowserTab?
    /// 스크롤 비율 (0...1) 통지. 스크롤 연동에 쓴다.
    var onScroll: ((Double, Double) -> Void)?
    /// 새 탭으로 열기 요청 (페이지가 연 새 창은 WebKit 설정과 함께, 링크 ⌘클릭은 설정 없이). 새 탭의 웹뷰를 돌려준다.
    var onOpenWindow: ((WKWebViewConfiguration?, URL?) -> WKWebView?)?
    /// 페이지가 스스로 닫음 (window.close)
    var onClose: (() -> Void)?
    /// 로그인 칸에 포커스 (칸의 viewport 좌표) → 계정 목록을 띄운다. nil 이면 숨긴다.
    var onLoginFocus: ((CGRect?) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    /// 진행 중인 다운로드와 저장 파일 이름
    fileprivate var downloads: [ObjectIdentifier: (download: WKDownload, name: String)] = [:]

    /// configuration: 페이지가 연 새 창이면 WebKit 이 준 설정 (저장소·window.opener 가 이어진다). 없으면 store 로 새로 만든다.
    init(tab: BrowserTab, store: WKWebsiteDataStore, configuration: WKWebViewConfiguration? = nil) {
        self.store = store
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = store }
        // Safari 로 식별 (기본 웹뷰 User-Agent 는 Safari 표시가 없어 구글 등이 단순한 화면을 보낸다)
        config.applicationNameForUserAgent = Self.safariUserAgentSuffix
        // 받은 설정은 연 탭의 controller 를 함께 쓰므로, 메시지가 섞이지 않게 항상 새로 만든다
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")   // 우클릭 "요소 검사"
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.helperScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        config.userContentController = controller
        webView = FocusAwareWebView(frame: .zero, configuration: config)
        self.tab = tab
        super.init()
        controller.add(WeakMessageHandler(self), name: "devlink")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        observe()
    }

    /// User-Agent 끝에 붙는 Safari 표시. Safari 버전은 macOS 버전과 같다 (macOS 26 부터).
    static let safariUserAgentSuffix = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"

    deinit {
        MainActor.assumeIsolated {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "devlink")
        }
    }

    // MARK: Navigation

    /// 파일은 같은 폴더(하위 포함)의 css·js·이미지를 함께 읽을 수 있게 연다.
    func load(_ url: URL) {
        if url.isFileURL {
            let folder = URL(fileURLWithPath: url.path(percentEncoded: false)).deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: folder)
        } else {
            webView.load(URLRequest(url: url))
        }
    }
    func reload(hard: Bool) {
        if hard { webView.reloadFromOrigin() } else { webView.reload() }
    }

    /// 모바일 보기: 웹뷰 크기는 그대로 두고 페이지가 레이아웃하는 폭만 지정한 폭으로 바꾼다 (비공개 API
    /// `_fixedLayoutSize`, 개발자 도구와 부딪히지 않는다). 켜고 끌 때(reload)는 iPhone User-Agent 도 바꿔 다시 로드한다.
    func setMobile(_ width: CGFloat?, reload: Bool) {
        typealias SetInt = @convention(c) (AnyObject, Selector, Int) -> Void
        typealias SetSize = @convention(c) (AnyObject, Selector, NSSize) -> Void
        let setMode = NSSelectorFromString("_setLayoutMode:"), setSize = NSSelectorFromString("_setFixedLayoutSize:")
        if webView.responds(to: setMode), webView.responds(to: setSize) {
            // 레이아웃 모드 1 = 고정 크기, 0 = 보통 (실험으로 확인)
            let size = width.map { NSSize(width: $0, height: max(webView.bounds.height, 600)) } ?? .zero
            unsafeBitCast(webView.method(for: setMode), to: SetInt.self)(webView, setMode, width == nil ? 0 : 1)
            unsafeBitCast(webView.method(for: setSize), to: SetSize.self)(webView, setSize, size)
        }
        if reload { applyUserAgent(); return }
        // 폭만 바뀐 경우: 룰러·안내선은 앱이 알려 준 폭(__lhViewW)으로 그려져 있으니, 레이아웃이 바뀐 뒤 다시 띄운다
        if tab?.isRulerOn == true {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                hideRulerOverlay()
                showRulerOverlay()
            }
        }
    }

    /// User-Agent 를 적용하고 다시 로드한다: 직접 고른 값 > 모바일 보기 중이면 iPhone > 기본값.
    func applyUserAgent() {
        webView.customUserAgent = tab?.userAgent?.string
            ?? (tab?.mobileWidth != nil ? UserAgentPreset.safariIPhone.string : nil)
        webView.reload()
    }

    /// Web Inspector(Safari 와 같은 개발자 도구)를 켜고 끈다. 열 때마다 페이지 오른쪽에 붙인다 (비공개 API, 없으면 무시).
    private var inspector: NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter) else { return nil }
        return webView.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    var isInspectorOpen: Bool { inspector?.value(forKey: "isVisible") as? Bool == true }

    // MARK: 전체 화면 스크린샷

    /// 문서 높이가 이보다 크면 여기까지만 찍는다 (CSS px). PDF 한 쪽의 크기 한계(14400)에 맞춘다.
    static let maxCaptureHeight: CGFloat = 14400

    /// 페이지 전체를 PNG 로 찍는다. 스크롤해 이어 붙이지 않고, WebKit 이 문서 전체를 한 번에 PDF 로 그리게 한 뒤 이미지로 바꾼다
    /// (고정 헤더가 한 번만 나오고, 화면에 보이는 부분만 그려지는 문제가 없다).
    /// 먼저 끝까지 스크롤해 지연 로딩·나타나는 효과를 불러 놓고 맨 위로 돌아와서 그린다.
    /// 가로: 기본은 문서 왼쪽 끝부터 현재 화면 오른쪽 끝까지, visibleWidthOnly 면 현재 화면에 보이는 폭만. 세로는 문서 전체.
    /// area: 문서 좌표(CSS px)의 사각형 — 주면 가로·세로 모두 그 범위만 찍는다 (visibleWidthOnly 는 무시).
    /// 돌려주는 값: (PNG 데이터, 높이가 잘렸는지)
    @MainActor
    func captureFullPage(visibleWidthOnly: Bool = false, area: CGRect? = nil) async throws -> (data: Data, truncated: Bool) {
        hideRulerOverlay()   // 룰러·안내선이 이미지에 찍히지 않게
        defer { showRulerOverlay() }
        let start = (try? await webView.evaluateJavaScript("[window.scrollX, window.scrollY]") as? [Double]) ?? [0, 0]
        let startX = start.first ?? 0, startY = start.last ?? 0
        defer {
            webView.evaluateJavaScript("window.scrollTo({ top: \(startY), left: \(startX), behavior: 'instant' })", completionHandler: nil)
        }
        // 끝까지 내려갔다가 맨 위로: 지연 로딩·스크롤 효과를 깨우고, 끝나는 애니메이션을 (최대 1.5초) 기다린다
        let measured = try await webView.callAsyncJavaScript("""
            const height = () => Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
            const step = Math.max(200, window.innerHeight * 0.9);
            for (let y = 0, i = 0; y < height() && i < 200; y += step, i++) {
              window.scrollTo({ top: y, left: 0, behavior: 'instant' });
              await new Promise((r) => setTimeout(r, 80));
            }
            window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
            await Promise.race([
              Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
              new Promise((r) => setTimeout(r, 1500)),
            ]);
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            return height();
            """, contentWorld: .page) as? Double ?? 0
        // 가로: 문서 왼쪽 끝부터 현재 화면의 오른쪽 끝까지 (가로 스크롤이 없으면 화면 폭). 세로: 문서 전체.
        // PDF 영역은 웹뷰 좌표(pt)라서 CSS px 값에 확대 배율을 곱한다.
        let zoom = webView.pageZoom
        var left = visibleWidthOnly ? CGFloat(startX) * zoom : 0   // 스크롤을 맨 왼쪽으로 돌린 뒤 그리므로 웹뷰 x = 문서 x
        // 모바일 보기: 웹뷰는 창 폭 그대로지만 페이지는 지정한 폭만 그리므로, 그 폭까지만 찍는다 (넘는 부분은 빈 흰색이 된다)
        let viewWidth = tab?.mobileWidth.map { min(webView.bounds.width, $0 * zoom) } ?? webView.bounds.width
        var wantedWidth = visibleWidthOnly ? viewWidth : CGFloat(startX) * zoom + viewWidth
        var top: CGFloat = 0
        var wantedHeight = max(webView.bounds.height, CGFloat(measured) * zoom)
        if let area {   // 영역 지정: 사각형 그대로 (문서 높이를 넘으면 문서 끝까지)
            left = area.minX * zoom
            wantedWidth = area.width * zoom
            top = min(area.minY, max(CGFloat(measured) - 1, 0)) * zoom
            wantedHeight = max(1, min(area.maxY, CGFloat(measured)) * zoom - top)
        }
        let truncated = wantedWidth > Self.maxCaptureHeight || wantedHeight > Self.maxCaptureHeight
        let width = min(wantedWidth, Self.maxCaptureHeight)
        let height = min(wantedHeight, Self.maxCaptureHeight)

        let config = WKPDFConfiguration()
        config.rect = CGRect(x: left, y: top, width: width, height: height)
        let pdf = try await webView.pdf(configuration: config)
        let backing = webView.window?.backingScaleFactor ?? 2
        guard let png = await Task.detached(priority: .userInitiated, operation: { Self.renderPNG(pdf: pdf, backingScale: backing) }).value else {
            throw CaptureError.encodeFailed
        }
        return (png, truncated)
    }


    // MARK: 영역 지정 (위·아래 선)

    /// 영역 선택이 끝났을 때: (위, 아래) 문서 CSS px, 취소면 nil
    var onAreaSelected: ((CGRect?) -> Void)?

    /// 페이지에 위·아래 선과 바깥 음영, 캡처/취소 막대를 띄운다. 선은 문서와 함께 스크롤된다.
    /// 확정·취소하면 오버레이를 스스로 지우고 onAreaSelected 로 알린다.
    @MainActor
    func beginAreaSelection() {
        let labels: [String: String] = [
            "capture": String(localized: "Capture"),
            "cancel": String(localized: "Cancel"),
            "hint": String(localized: "Drag the lines, or pull the top/left lines out of the rulers"),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: labels)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let palette = (try? JSONSerialization.data(withJSONObject: GuideColor.allCases.map(\.hex))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // 영역 선택 중에는 룰러 화면을 잠가 둔다: 안내선만 보이고 마우스에는 반응하지 않는다. 룰러가 꺼져 있으면 안내선도 없다.
        // 끝나면 룰러 화면을 다시 띄워서(잠금 해제) 돌려놓는다.
        webView.evaluateJavaScript("window.__lhRulerLock && window.__lhRulerLock(true)", completionHandler: nil)
        func numbers(_ values: [Double]) -> String {
            (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        let rulerOn = tab?.isRulerOn == true
        let guidesX = rulerOn ? numbers(tab?.guidesX ?? []) : "[]", guidesY = rulerOn ? numbers(tab?.guidesY ?? []) : "[]"
        webView.evaluateJavaScript(viewWidthPrefix + Self.areaScript.replacingOccurrences(of: "__RULER_DRAW__", with: Self.rulerDrawScript)
            .replacingOccurrences(of: "__COLORS__", with: palette)
            .replacingOccurrences(of: "__GUIDES_X__", with: guidesX)
            .replacingOccurrences(of: "__GUIDES_Y__", with: guidesY)
            .replacingOccurrences(of: "__COLOR_INDEX__", with: String(GuideColor.allCases.firstIndex(of: AppSettings.captureColor) ?? 0))
            .replacingOccurrences(of: "__LABELS__", with: json), completionHandler: nil)
    }

    /// 선택 중이면 취소 (오버레이 제거)
    @MainActor
    func cancelAreaSelection() {
        webView.evaluateJavaScript("window.__lhAreaClose && window.__lhAreaClose(false)", completionHandler: nil)
    }


    /// 눈금을 그리는 공통 스크립트 (영역 선택·룰러 모드). marksX/marksY: 위/왼쪽 룰러에 색으로 표시할 문서 좌표.
    private static let rulerDrawScript = """
    // 모바일 보기: 웹뷰는 창 폭 그대로라 innerWidth 가 페이지가 그리는 폭보다 크다 → 앱이 알려 준 폭을 쓴다
    function lhVW(){ return window.__lhViewW || window.innerWidth; }
    function lhDrawRulers(cT, cL, RW, hot, color, marksX, marksY){
      var dpr = window.devicePixelRatio || 1, iw = lhVW(), ih = window.innerHeight, sx = window.scrollX, sy = window.scrollY;
      function prep(c, w, h){
        c.style.width = w + 'px'; c.style.height = h + 'px'; c.width = Math.max(1, Math.round(w * dpr)); c.height = Math.max(1, Math.round(h * dpr));
        var g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0);
        g.fillStyle = hot ? 'rgba(10,132,255,.6)' : 'rgba(30,30,30,.5)'; g.fillRect(0, 0, w, h);   // 반투명: 룰러 아래 페이지가 대충 보이게
        g.strokeStyle = '#aaa'; g.fillStyle = '#ddd'; g.lineWidth = 1; g.font = '9px -apple-system,sans-serif';
        return g;
      }
      function len(v){ return v % 100 === 0 ? 14 : v % 50 === 0 ? 8 : 4; }
      var g = prep(cT, Math.max(1, iw - RW), RW), v, c;
      for (v = Math.floor(sx / 10) * 10; v <= sx + iw; v += 10) {
        c = v - sx - RW + 0.5; if (c < 0) continue;
        g.beginPath(); g.moveTo(c, RW); g.lineTo(c, RW - len(v)); g.stroke();
        if (v % 100 === 0) g.fillText(String(v), c + 2, 9);
      }
      g.fillStyle = color;
      marksX.forEach(function(p){ var q = p - sx - RW; if (q >= -1 && q <= iw) g.fillRect(Math.round(q) - 1, 0, 2, RW); });
      g = prep(cL, RW, Math.max(1, ih - RW));
      for (v = Math.floor(sy / 10) * 10; v <= sy + ih; v += 10) {
        c = v - sy - RW + 0.5; if (c < 0) continue;
        g.beginPath(); g.moveTo(RW, c); g.lineTo(RW - len(v), c); g.stroke();
        if (v % 100 === 0) { g.save(); g.translate(9, c - 2); g.rotate(-Math.PI / 2); g.fillText(String(v), 0, 0); g.restore(); }
      }
      g.fillStyle = color;
      marksY.forEach(function(p){ var q = p - sy - RW; if (q >= -1 && q <= ih) g.fillRect(0, Math.round(q) - 1, RW, 2); });
    }
    // 배지 글자색: 밝은 색 위에는 검정
    function lhInk(hex){
      var n = parseInt(hex.slice(1), 16), r = n >> 16, g = (n >> 8) & 255, b = n & 255;
      return (r * 299 + g * 587 + b * 114) / 1000 > 150 ? '#000000' : '#ffffff';
    }
    // 간격 표시(측정선 + 배지)의 스타일. 안내선·선택 선과 구분되도록 색(--c)을 쓰지 않고 중립 회색에 밝은 외곽을 둔다
    function lhGapCss(){
      var N = 'rgba(30,30,30,.92)';
      return '.sp{position:fixed;pointer-events:none;filter:drop-shadow(0 0 1px rgba(255,255,255,.95))}' +
        '.spx{height:9px;border:0 solid ' + N + ';border-left-width:1px;border-right-width:1px}' +
        '.spy{width:9px;border:0 solid ' + N + ';border-top-width:1px;border-bottom-width:1px}' +
        '.spx::after{content:"";position:absolute;left:0;right:0;top:4px;height:1px;background:' + N + '}' +
        '.spy::after{content:"";position:absolute;top:0;bottom:0;left:4px;width:1px;background:' + N + '}' +
        '.bg{position:fixed;pointer-events:none;padding:1px 5px;border-radius:4px;background:' + N + ';color:#fff;box-shadow:0 0 0 1px rgba(255,255,255,.55);font:11px -apple-system,system-ui,sans-serif;white-space:nowrap}' +
        '.bgx{transform:translate(-50%,-100%);margin-top:-2px}.bgy{transform:translateY(-50%);margin-left:6px}';
    }
    // 문서 좌표 a~b 사이 간격을 box 에 그린다 (화면에 보이는 부분 가운데에). cross: 다른 축 쪽 위치(화면 좌표).
    // axis 'x': 가로 간격 (cross = 화면 y), 'y': 세로 간격 (cross = 화면 x)
    function lhGap(box, axis, a, b, RW, cross, fit){
      var lo = axis === 'x' ? window.scrollX : window.scrollY, view = axis === 'x' ? lhVW() : window.innerHeight;
      var from = Math.max(a, lo + RW), to = Math.min(b, lo + view);
      if (b - a <= 0 || to <= from) return;
      var A = from - lo, B = to - lo, sp = document.createElement('div'), bg = document.createElement('div');
      sp.className = 'sp sp' + axis; bg.className = 'bg bg' + axis;
      bg.textContent = Math.round(b - a) + ' px';
      if (fit && (to - from) < (axis === 'x' ? bg.textContent.length * 6.5 + 12 : 18)) return;   // fit: 배지가 들어가지 않는 좁은 간격은 숨긴다
      if (axis === 'x') {
        sp.style.left = A + 'px'; sp.style.width = (B - A) + 'px'; sp.style.top = (cross - 4) + 'px';
        if (a < lo + RW) sp.style.borderLeftWidth = '0'; if (b > lo + view) sp.style.borderRightWidth = '0';
        bg.style.left = (A + B) / 2 + 'px'; bg.style.top = cross + 'px';
      } else {
        sp.style.top = A + 'px'; sp.style.height = (B - A) + 'px'; sp.style.left = (cross - 4) + 'px';
        if (a < lo + RW) sp.style.borderTopWidth = '0'; if (b > lo + view) sp.style.borderBottomWidth = '0';
        bg.style.top = (A + B) / 2 + 'px'; bg.style.left = (cross + 4) + 'px';
      }
      box.appendChild(sp); box.appendChild(bg);
    }
    """

    // MARK: 룰러·안내선 모드

    /// 룰러 모드가 켜져 있으면 페이지에 룰러와 안내선을 띄운다 (안내선은 탭이 기억하고, 페이지가 바뀌면 다시 그린다).
    @MainActor
    func showRulerOverlay() {
        guard let tab, tab.isRulerOn else { return }
        let labels: [String: String] = [
            "remove": String(localized: "Release to delete"),
            "clear": String(localized: "Clear all guides"),
        ]
        func json(_ object: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        let script = Self.rulerScript
            .replacingOccurrences(of: "__RULER_DRAW__", with: Self.rulerDrawScript)
            .replacingOccurrences(of: "__LABELS__", with: json(labels))
            .replacingOccurrences(of: "__COLOR__", with: tab.guideColor.hex)
            .replacingOccurrences(of: "__GUIDES__", with: json(["x": tab.guidesX, "y": tab.guidesY]))
        webView.evaluateJavaScript(viewWidthPrefix + script, completionHandler: nil)
    }

    /// 스크립트 앞에 붙이는 한 줄: 모바일 보기면 페이지가 그리는 폭 (CSS px), 아니면 0
    private var viewWidthPrefix: String { "window.__lhViewW = \(Int(tab?.mobileWidth ?? 0));\n" }

    /// 룰러·안내선 화면만 지운다 (안내선 기억은 그대로). 캡처·영역 선택 전에 쓴다.
    @MainActor
    func hideRulerOverlay() {
        webView.evaluateJavaScript("window.__lhRulerClose && window.__lhRulerClose()", completionHandler: nil)
    }

    private static let rulerScript = """
    (function(){
      if (window.__lhRulerClose) window.__lhRulerClose();
      var L = __LABELS__;
      var RW = 20, COLOR = '__COLOR__';   // 룰러 두께, 안내선 색
      var init = __GUIDES__;
      var de = document.documentElement;
      var host = document.createElement('div');
      host.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;overflow:hidden;z-index:2147483647;pointer-events:none;--c:' + COLOR + ';--ink:' + lhInk(COLOR);
      var root = host.attachShadow({mode:'closed'});
      var style = document.createElement('style');
      style.textContent = '*{box-sizing:border-box}' +
        '.g{position:absolute;pointer-events:auto;touch-action:none}' +
        '.gy{left:0;height:14px;margin-top:-7px;cursor:ns-resize}.gx{top:0;width:14px;margin-left:-7px;cursor:ew-resize}' +
        '.g::after{content:"";position:absolute;background:' + COLOR + ';box-shadow:0 0 0 1px rgba(255,255,255,.5)}' +
        '.gy::after{left:0;right:0;top:7px;height:1px}.gx::after{top:0;bottom:0;left:7px;width:1px}' +
        '.ruler{position:fixed;display:block;pointer-events:auto;touch-action:none}' +
        '.rt{left:' + RW + 'px;top:0;cursor:ns-resize}.rl{left:0;top:' + RW + 'px;cursor:ew-resize}' +
        '.corner{position:fixed;left:0;top:0;width:' + RW + 'px;height:' + RW + 'px;background:rgba(30,30,30,.5);color:#eee;text-shadow:0 0 2px #000;' +
        'display:flex;align-items:center;justify-content:center;padding-bottom:3px;font:13px/1 -apple-system,system-ui,sans-serif;cursor:pointer;pointer-events:auto}' +
        '.corner:hover{color:#fff}' +
        // 잠금(영역 선택 중): 안내선만 보이고 마우스에 반응하지 않는다. 룰러·모서리·간격 표시는 숨긴다
        ':host([data-lock]) .g{pointer-events:none}:host([data-lock]) .ruler,:host([data-lock]) .corner,:host([data-lock]) .tip{display:none!important}' +
        lhGapCss() +
        '.tip{position:fixed;display:none;padding:3px 8px;border-radius:6px;background:rgba(30,30,30,.92);color:#fff;font:12px -apple-system,system-ui,sans-serif;white-space:nowrap;pointer-events:none}';
      root.appendChild(style);
      var cT = document.createElement('canvas'); cT.className = 'ruler rt'; root.appendChild(cT);   // 위 룰러: 가로 안내선을 꺼낸다
      var cL = document.createElement('canvas'); cL.className = 'ruler rl'; root.appendChild(cL);   // 왼쪽 룰러: 세로 안내선을 꺼낸다
      var corner = document.createElement('div'); corner.className = 'corner'; corner.textContent = '×'; corner.title = L.clear; root.appendChild(corner);
      var tip = document.createElement('div'); tip.className = 'tip'; root.appendChild(tip);
      var gaps = document.createElement('div'); root.insertBefore(gaps, cT);
      __RULER_DRAW__
      function measure(){
        host.style.display = 'none';
        var m = {W: de.scrollWidth, H: Math.max(de.scrollHeight, document.body ? document.body.scrollHeight : 0)};
        host.style.display = '';
        return m;
      }
      var dims = measure();
      var gs = [];   // {axis: 'x' | 'y', v: 문서 좌표, el}
      function px(n){ return Math.round(n) + 'px'; }
      function post(m){ try { webkit.messageHandlers.devlink.postMessage(m); } catch(e){} }
      function save(){
        post({t:'guides', x: gs.filter(function(g){ return g.axis === 'x'; }).map(function(g){ return g.v; }),
                          y: gs.filter(function(g){ return g.axis === 'y'; }).map(function(g){ return g.v; })});
      }
      var drag = null, hovered = null, lastX = 0, lastY = 0;
      function inRuler(){ return lastX < RW || lastY < RW; }
      function render(){
        host.style.width = px(dims.W); host.style.height = px(dims.H);
        gs.forEach(function(g){
          if (g.axis === 'y') { g.el.style.top = px(g.v); g.el.style.width = px(dims.W); }
          else { g.el.style.left = px(g.v); g.el.style.height = px(dims.H); }
        });
        var hot = !!drag && inRuler();
        lhDrawRulers(cT, cL, RW, hot, COLOR,
          gs.filter(function(g){ return g.axis === 'x'; }).map(function(g){ return g.v; }),
          gs.filter(function(g){ return g.axis === 'y'; }).map(function(g){ return g.v; }));
        drawGaps();
        if (!drag) { tip.style.display = 'none'; return; }
        tip.textContent = hot ? L.remove : (drag.axis === 'y' ? 'Y ' : 'X ') + Math.round(drag.v);
        tip.style.display = 'block';
        tip.style.left = Math.min(lastX + 16, lhVW() - 150) + 'px';
        tip.style.top = Math.min(lastY + 20, window.innerHeight - 30) + 'px';
      }
      // 안내선 사이 거리: 선에 마우스를 올리거나 끄는 동안, 같은 방향의 모든 간격을 룰러 원점(0)부터 차례로 보인다
      // (좁아서 안 들어가는 배지는 숨김). 화면에 보이는 부분 가운데에 표시한다.
      function drawGaps(){
        gaps.textContent = '';
        var focus = drag || hovered;
        if (!focus) return;
        var iw = lhVW(), ih = window.innerHeight, axis = focus.axis;
        var same = gs.filter(function(g){ return g.axis === axis; }).sort(function(p, q){ return p.v - q.v; });
        same.forEach(function(g, k){ lhGap(gaps, axis, k > 0 ? same[k - 1].v : 0, g.v, RW, axis === 'x' ? ih / 2 : iw / 2, true); });
      }
      function move(){
        if (!drag) return;
        drag.v = Math.max(0, Math.min(drag.axis === 'y' ? lastY + window.scrollY : lastX + window.scrollX, drag.axis === 'y' ? dims.H : dims.W));
        render();
      }
      function end(){
        if (!drag) return;
        if (inRuler()) { drag.el.remove(); gs.splice(gs.indexOf(drag), 1); hovered = null; }   // 룰러로 끌어다 놓으면 지운다
        drag = null; render(); save();
      }
      function begin(g, node, e){
        drag = g; dims = measure(); lastX = e.clientX; lastY = e.clientY;
        node.setPointerCapture(e.pointerId); e.preventDefault(); move();
      }
      function track(node){
        node.addEventListener('pointermove', function(e){ lastX = e.clientX; lastY = e.clientY; move(); });
        node.addEventListener('pointerup', end);
        node.addEventListener('pointercancel', end);
      }
      function addGuide(axis, v){
        var el = document.createElement('div'); el.className = 'g ' + (axis === 'y' ? 'gy' : 'gx');
        root.insertBefore(el, cT);
        var g = {axis: axis, v: v, el: el}; gs.push(g);
        el.addEventListener('pointerdown', function(e){ begin(g, el, e); });
        el.addEventListener('pointerenter', function(){ hovered = g; render(); });
        el.addEventListener('pointerleave', function(){ if (hovered === g) { hovered = null; render(); } });
        track(el);
        return g;
      }
      cT.addEventListener('pointerdown', function(e){ begin(addGuide('y', 0), cT, e); }); track(cT);
      cL.addEventListener('pointerdown', function(e){ begin(addGuide('x', 0), cL, e); }); track(cL);
      corner.addEventListener('click', function(){ gs.forEach(function(g){ g.el.remove(); }); gs = []; hovered = null; render(); save(); });
      (init.y || []).forEach(function(v){ addGuide('y', v); });
      (init.x || []).forEach(function(v){ addGuide('x', v); });
      function onScroll(){ if (drag) move(); else render(); }
      function onResize(){ dims = measure(); render(); }
      window.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', onResize);
      window.__lhRulerLock = function(on){
        if (on) { drag = null; hovered = null; host.setAttribute('data-lock', ''); render(); }
        else host.removeAttribute('data-lock');
      };
      window.__lhRulerClose = function(){
        window.removeEventListener('scroll', onScroll, true); window.removeEventListener('resize', onResize);
        host.remove(); window.__lhRulerClose = null; window.__lhRulerLock = null;
      };
      de.appendChild(host); render();
    })();
    """

    private static let areaScript = """
    (function(){
      if (window.__lhAreaClose) window.__lhAreaClose(false);
      var L = __LABELS__;
      var MIN = 60, RW = 20;   // 최소 폭·높이 (CSS px), 룰러 두께
      var GX = __GUIDES_X__, GY = __GUIDES_Y__, SNAP = 6;   // 룰러 안내선(문서 좌표)과 붙는 거리 (CSS px)
      function snap(v, list){
        var best = v, d = SNAP + 1;
        list.forEach(function(g){ var k = Math.abs(g - v); if (k < d) { d = k; best = g; } });
        return d <= SNAP ? best : v;
      }
      var COLORS = __COLORS__, START = Math.max(0, __COLOR_INDEX__);   // 설정의 영역 선 색이 처음 선택된 색
      var color = COLORS[START];
      var de = document.documentElement;
      var host = document.createElement('div');
      host.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;overflow:hidden;z-index:2147483647;pointer-events:none;--c:' + color + ';--ink:' + lhInk(color);
      var root = host.attachShadow({mode:'closed'});
      var style = document.createElement('style');
      style.textContent = '*{box-sizing:border-box} .dim{position:absolute;background:rgba(0,0,0,.45);pointer-events:none}' +
        '.line{position:absolute;pointer-events:auto;touch-action:none}' +
        '.h{left:0;height:14px;margin-top:-7px;cursor:ns-resize}.v{top:0;width:14px;margin-left:-7px;cursor:ew-resize}' +
        '.pt{position:absolute;width:20px;height:20px;margin:-10px 0 0 -10px;pointer-events:auto;touch-action:none}' +
        '.line::after{content:"";position:absolute;background:var(--c)}' +
        '.h::after{left:0;right:0;height:2px}.v::after{top:0;bottom:0;width:2px}' +
        // 선은 캡처 영역 바깥쪽에 붙여 그린다: 선의 안쪽 가장자리가 곧 캡처 경계
        '.h.t::after{top:5px}.h.b::after{top:7px}.v.l::after{left:5px}.v.r::after{left:7px}' +
        '.size{position:fixed;display:none;transform:translate(-50%,-50%);padding:2px 8px;border-radius:4px;background:var(--c);color:var(--ink);font:12px -apple-system,system-ui,sans-serif;white-space:nowrap;pointer-events:none}' +
        '.tip{position:fixed;display:none;padding:3px 8px;border-radius:6px;background:rgba(30,30,30,.92);color:#fff;font:12px -apple-system,system-ui,sans-serif;white-space:nowrap;pointer-events:none}' +
        '.ruler{position:fixed;display:block;pointer-events:auto;touch-action:none}' +
        '.rt{left:' + RW + 'px;top:0;cursor:ns-resize}.rl{left:0;top:' + RW + 'px;cursor:ew-resize}' +
        '.corner{position:fixed;left:0;top:0;width:' + RW + 'px;height:' + RW + 'px;background:rgba(30,30,30,.5);pointer-events:auto;touch-action:none;cursor:nwse-resize}' +
        '.bar{position:fixed;top:' + (RW + 12) + 'px;left:50%;transform:translateX(-50%);display:flex;gap:8px;align-items:center;padding:6px 10px;border-radius:10px;' +
        'background:rgba(30,30,30,.92);color:#fff;font:13px -apple-system,system-ui,sans-serif;pointer-events:auto;box-shadow:0 2px 10px rgba(0,0,0,.4);' +
        'white-space:nowrap;max-width:calc(100vw - 60px)}' +
        '.bar span{min-width:0;overflow:hidden;text-overflow:ellipsis}' +
        '.bar button{flex:none;font:inherit;border:0;border-radius:6px;padding:4px 12px;cursor:pointer;background:#555;color:#fff}' +
        '.bar button.go{background:#0a84ff}' +
        '.bar button.sw{width:18px;height:18px;padding:0;border-radius:9px;border:0;box-shadow:inset 0 0 0 1px rgba(255,255,255,.35)}';
      root.appendChild(style);
      function el(cls, parent){ var d = document.createElement('div'); d.className = cls; parent.appendChild(d); return d; }
      var dT = el('dim', root), dB = el('dim', root), dL = el('dim', root), dR = el('dim', root);
      function makeLine(cls){ return el('line ' + cls, root); }
      var lT = makeLine('h t'), lB = makeLine('h b'), lL = makeLine('v l'), lR = makeLine('v r');
      // 두 선의 접점(±10px)을 잡으면 두 선이 같이 움직인다 (보이는 표시 없이 커서만 바뀐다)
      var pTL = el('pt', root), pTR = el('pt', root), pBL = el('pt', root), pBR = el('pt', root);
      pTL.style.cursor = pBR.style.cursor = 'nwse-resize'; pTR.style.cursor = pBL.style.cursor = 'nesw-resize';
      var size = el('size', root);   // 선택 영역의 가로 × 세로 크기 (눈금보다 아래에 그린다)
      var cT = document.createElement('canvas'); cT.className = 'ruler rt'; root.appendChild(cT);   // 위 룰러: 위쪽 선을 꺼낸다
      var cL = document.createElement('canvas'); cL.className = 'ruler rl'; root.appendChild(cL);   // 왼쪽 룰러: 왼쪽 선을 꺼낸다
      var cc = el('corner', root);   // 룰러 모서리: 눌러 끌면 위·왼쪽 선이 함께 나온다 (이미 나온 선은 다시 시작)
      var bar = el('bar', root);
      var hint = document.createElement('span'); hint.textContent = L.hint; bar.appendChild(hint);
      var swatches = COLORS.map(function(c){
        var b = document.createElement('button'); b.className = 'sw'; b.style.background = c; bar.appendChild(b);
        b.addEventListener('click', function(){ color = c; host.style.setProperty('--c', c); host.style.setProperty('--ink', lhInk(c)); mark(); render(); });
        return b;
      });
      // 선택된 색은 가운데 점으로 표시한다 (룰러 색 메뉴와 같은 규칙, 밝은 색 위에는 검정 점)
      function mark(){ swatches.forEach(function(s, i){
        s.style.backgroundImage = (COLORS[i] === color) ? 'radial-gradient(circle, ' + lhInk(COLORS[i]) + ' 0 3px, transparent 3.5px)' : 'none'; }); }
      mark();
      var ok = document.createElement('button'); ok.className = 'go'; ok.textContent = L.capture; bar.appendChild(ok);
      var no = document.createElement('button'); no.textContent = L.cancel; bar.appendChild(no);
      // 문서 크기는 오버레이를 잠깐 숨기고 잰다 (오버레이 자신이 문서를 넓혀서, 창이 줄어도 크기가 줄지 않는 것을 막는다)
      function measure(){
        host.style.display = 'none';
        // innerWidth/innerHeight 는 스크롤바 두께를 포함해서, 오버레이를 그만큼 크게 만들어 스크롤을 남긴다 → scroll 크기만 쓴다 (화면보다 작지 않다)
        var m = {W: de.scrollWidth, H: Math.max(de.scrollHeight, document.body ? document.body.scrollHeight : 0)};
        host.style.display = '';
        return m;
      }
      var dims = measure();
      // 위·왼쪽 선은 룰러에 들어가 있으면(docked) 문서 0 부터. 창 크기가 바뀌어도 문서 좌표 그대로 둔다.
      var dockT = true, dockL = true, top = 0, left = 0;
      var right = window.scrollX + lhVW() * 0.8, bottom = window.scrollY + window.innerHeight * 0.8;
      function px(n){ return Math.round(n) + 'px'; }
      __RULER_DRAW__
      function drawRulers(hot){ lhDrawRulers(cT, cL, RW, hot, color, [left, right], [top, bottom]); }
      function render(){
        var W = dims.W, H = dims.H;
        host.style.width = px(W); host.style.height = px(H);
        function box(d, x, y, w, h){ d.style.left = px(x); d.style.top = px(y); d.style.width = px(Math.max(0, w)); d.style.height = px(Math.max(0, h)); }
        box(dT, 0, 0, W, top); box(dB, 0, bottom, W, H - bottom);
        box(dL, 0, top, left, bottom - top); box(dR, right, top, W - right, bottom - top);
        [[pTL, left, top], [pTR, right, top], [pBL, left, bottom], [pBR, right, bottom]].forEach(function(p){
          p[0].style.left = px(p[1]); p[0].style.top = px(p[2]); });
        pTL.style.display = (dockT || dockL) ? 'none' : 'block'; pTR.style.display = dockT ? 'none' : 'block'; pBL.style.display = dockL ? 'none' : 'block';
        lT.style.display = dockT ? 'none' : 'block'; lL.style.display = dockL ? 'none' : 'block';
        [[lT, top], [lB, bottom]].forEach(function(p){ p[0].style.top = px(p[1]); p[0].style.width = px(W); });
        [[lL, left], [lR, right]].forEach(function(p){ p[0].style.left = px(p[1]); p[0].style.height = px(H); });
        var hot = fromLine && (drag === 'top' || drag === 'left') && (lastX < RW || lastY < RW);
        drawRulers(hot);
        drawSize();
        drawTip(hot);
      }
      // 선택 영역의 가로 × 세로 크기: 영역의 보이는 부분 한가운데에 하나만, 항상 표시한다 (캡처 직전에 지워진다)
      function drawSize(){
        var sx = window.scrollX, sy = window.scrollY;
        var y0 = Math.max(top, sy + RW) - sy, y1 = Math.min(bottom, sy + window.innerHeight) - sy;
        var x0 = Math.max(left, sx + RW) - sx, x1 = Math.min(right, sx + lhVW()) - sx;
        if (y1 <= y0 || x1 <= x0) { size.style.display = 'none'; return; }
        size.textContent = Math.round(right - left) + ' × ' + Math.round(bottom - top) + ' px';
        size.style.display = 'block';
        size.style.left = (x0 + x1) / 2 + 'px'; size.style.top = (y0 + y1) / 2 + 'px';
      }
      // 선을 끄는 동안 풍선: 룰러의 픽셀 값(선 위치). 룰러로 끌고 가면 0 (놓으면 들어간다)
      var tip = el('tip', root);
      function drawTip(hot){
        if (!drag) { tip.style.display = 'none'; return; }
        if (drag.length === 2) {   // 접점: 두 선의 위치를 함께 보여준다
          tip.textContent = 'X ' + Math.round(drag[1] === 'l' ? left : right) + '  Y ' + Math.round(drag[0] === 't' ? top : bottom);
          tip.style.display = 'block';
          tip.style.left = Math.min(lastX + 16, lhVW() - 150) + 'px';
          tip.style.top = Math.min(lastY + 20, window.innerHeight - 30) + 'px';
          return;
        }
        var vertical = drag === 'top' || drag === 'bottom';   // 가로선이면 Y, 세로선이면 X
        var pos = hot ? 0 : ({top: top, bottom: bottom, left: left, right: right})[drag];
        tip.textContent = (vertical ? 'Y ' : 'X ') + Math.round(pos);
        tip.style.display = 'block';
        tip.style.left = Math.min(lastX + 16, lhVW() - 150) + 'px';
        tip.style.top = Math.min(lastY + 20, window.innerHeight - 30) + 'px';
      }
      function layout(){ dims = measure(); render(); }
      var drag = null, fromLine = false, lastX = 0, lastY = 0;
      function clamp(v, a, b){ return Math.max(a, Math.min(v, b)); }
      function move(){
        if (!drag) return;
        var x = snap(lastX + window.scrollX, GX), y = snap(lastY + window.scrollY, GY);
        if (drag.length === 2) {   // 접점: 'tl' 'tr' 'bl' 'br' = (위/아래)(왼/오른쪽) 선을 각각 따로 움직인다
          if (drag[0] === 't') { top = clamp(y, 0, bottom - MIN); } else bottom = clamp(y, top + MIN, Math.max(dims.H, top + MIN));
          if (drag[1] === 'l') { left = clamp(x, 0, right - MIN); } else right = clamp(x, left + MIN, Math.max(dims.W, left + MIN));
        }
        else if (drag === 'top') { top = clamp(y, 0, bottom - MIN); dockT = false; }
        else if (drag === 'bottom') bottom = clamp(y, top + MIN, Math.max(dims.H, top + MIN));
        else if (drag === 'left') { left = clamp(x, 0, right - MIN); dockL = false; }
        else right = clamp(x, left + MIN, Math.max(dims.W, left + MIN));
        render();
      }
      function end(){
        // 위·왼쪽 선을 룰러로 끌어다 놓으면 다시 들어간다 (문서 0 부터)
        if (drag === 'tl' && !fromLine) {   // 모서리에서 시작한 끌기: 선마다 룰러 쪽에 놓였는지 따로 본다
          if (lastY < RW) { dockT = true; top = 0; }
          if (lastX < RW) { dockL = true; left = 0; }
        }
        if (drag && fromLine && (lastX < RW || lastY < RW)) {
          if (drag === 'top') { dockT = true; top = 0; }
          if (drag === 'left') { dockL = true; left = 0; }
        }
        drag = null; fromLine = false; render();
      }
      function wire(node, name, line){
        node.addEventListener('pointerdown', function(e){
          drag = name; fromLine = line; dims = measure(); lastX = e.clientX; lastY = e.clientY;
          node.setPointerCapture(e.pointerId); e.preventDefault(); move();
        });
        node.addEventListener('pointermove', function(e){ lastX = e.clientX; lastY = e.clientY; move(); });
        node.addEventListener('pointerup', end);
        node.addEventListener('pointercancel', end);
      }
      wire(lT, 'top', true); wire(lB, 'bottom', true); wire(lL, 'left', true); wire(lR, 'right', true);
      wire(pTL, 'tl', true); wire(pTR, 'tr', true); wire(pBL, 'bl', true); wire(pBR, 'br', true);
      cc.addEventListener('pointerdown', function(){ dockT = false; dockL = false; });   // wire 의 핸들러보다 먼저 실행된다
      wire(cc, 'tl', false);
      wire(cT, 'top', false); wire(cL, 'left', false);   // 룰러를 누르면 그 위치에 선이 나온다 (끌면 따라간다)
      function onScroll(){ if (drag) move(); else render(); }
      window.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', layout);
      function post(m){ try { webkit.messageHandlers.devlink.postMessage(m); } catch(e){} }
      function onKey(e){ if (e.key === 'Escape') { e.preventDefault(); close(false); } }
      function close(confirm){
        window.removeEventListener('scroll', onScroll, true); window.removeEventListener('resize', layout);
        window.removeEventListener('keydown', onKey, true);
        host.remove(); window.__lhAreaClose = null;
        post(confirm ? {t:'area', left: left, right: right, top: top, bottom: bottom} : {t:'areaCancel'});
      }
      window.__lhAreaClose = close;
      ok.addEventListener('click', function(){ close(true); });
      no.addEventListener('click', function(){ close(false); });
      window.addEventListener('keydown', onKey, true);
      de.appendChild(host); render();
    })();
    """

    /// PDF 한 쪽을 화면 배율의 PNG 로 (너무 크면 배율을 낮춘다)
    nonisolated private static func renderPNG(pdf: Data, backingScale: CGFloat) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        var scale = max(1, backingScale)
        let maxPixels: CGFloat = 120_000_000
        if box.width * box.height * scale * scale > maxPixels { scale = max(1, (maxPixels / (box.width * box.height)).squareRoot()) }
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    enum CaptureError: Error { case encodeFailed }

    func toggleInspector() {
        guard let inspector else { return }
        if isInspectorOpen {
            inspector.perform(NSSelectorFromString("hide"))
            return
        }
        inspector.perform(NSSelectorFromString("attach"))
        inspector.perform(NSSelectorFromString("show"))
        dockInspectorRight(inspector, tries: 25)
    }

    /// 인스펙터 화면이 뜰 때까지 기다렸다가 오른쪽 도킹을 요청한다 (인스펙터 자체의 도킹 버튼과 같은 호출).
    private func dockInspectorRight(_ inspector: NSObject, tries: Int) {
        guard tries > 0 else { return }
        guard let view = inspector.value(forKey: "inspectorWebView") as? WKWebView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.dockInspectorRight(inspector, tries: tries - 1) }
            return
        }
        view.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('right'), true") { [weak self] ok, _ in
            if ok as? Bool == true { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.dockInspectorRight(inspector, tries: tries - 1) }
        }
    }

    // MARK: Storage

    func clear(_ kind: ClearKind) async {
        await store.removeData(ofTypes: kind.types, modifiedSince: .distantPast)
        await refreshCookieCount()
        if kind == .all { webView.reloadFromOrigin() }
    }

    func refreshCookieCount() async {
        let cookies = await store.httpCookieStore.allCookies()
        tab?.cookieCount = cookies.count
    }

    // MARK: 로그인 채우기

    /// 마지막으로 포커스한 로그인 칸에 아이디(와 비밀번호)를 넣는다. 제출은 하지 않는다.
    func fillLogin(id: String, password: String?) {
        let values: [Any] = [id, password.map { $0 as Any } ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let args = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__lhFill && window.__lhFill.apply(null, \(args))", completionHandler: nil)
        webView.window?.makeFirstResponder(webView)
    }

    // MARK: Scroll sync

    /// 다른 화면의 스크롤 비율을 적용. 적용으로 생긴 스크롤 이벤트는 다시 보내지 않는다.
    func applyScroll(x: Double, y: Double) {
        let js = """
        (function(){ var se=document.scrollingElement||document.documentElement;
          window.__lhSyncing=Date.now();
          window.scrollTo(\(x)*Math.max(0,se.scrollWidth-innerWidth), \(y)*Math.max(0,se.scrollHeight-innerHeight)); })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static let helperScript = """
    (function(){
      if (window.__devlink) return; window.__devlink = true;
      function post(m){ try { webkit.messageHandlers.devlink.postMessage(m); } catch(e){} }
      document.addEventListener('mouseover', function(e){
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        post({t:'hover', href: a ? a.href : ''});
      }, true);
      document.addEventListener('mouseleave', function(){ post({t:'hover', href:''}); });
      // 로그인 칸: 보이는 비밀번호 칸과 그 앞의 아이디 칸 (아이디만 먼저 받는 화면은 autocomplete=username 칸)
      function visible(el){ return el.offsetParent !== null && !el.disabled && !el.readOnly; }
      function textLike(el){ var t = (el.getAttribute('type') || 'text').toLowerCase(); return t === 'text' || t === 'email' || t === 'tel'; }
      function loginFields(el){
        if (!(el instanceof HTMLInputElement) || !visible(el)) return null;
        var isPass = el.type === 'password';
        if (!isPass && !textLike(el)) return null;
        var inputs = Array.prototype.slice.call((el.form || document).querySelectorAll('input'));
        var pass = isPass ? el : inputs.filter(function(i){ return i.type === 'password' && visible(i); })[0] || null;
        if (!pass) return /username/.test(el.autocomplete || '') ? {user: el, pass: null} : null;
        if (isPass) {
          var before = inputs.slice(0, inputs.indexOf(el)).filter(function(i){ return textLike(i) && visible(i); });
          return {user: before[before.length - 1] || null, pass: el};
        }
        return inputs.indexOf(el) < inputs.indexOf(pass) ? {user: el, pass: pass} : null;
      }
      var lastLogin = 0;
      function onLoginFocus(e){
        var f = loginFields(e.target);
        if (!f) { if (e.type === 'mousedown') post({t:'loginHide'}); return; }
        if (Date.now() - lastLogin < 300) return;   // 클릭하면 focusin·mousedown 이 함께 온다
        lastLogin = Date.now();
        window.__lhLogin = f;
        var r = e.target.getBoundingClientRect();
        post({t:'login', x: r.left, y: r.top, w: r.width, h: r.height});
      }
      document.addEventListener('focusin', onLoginFocus, true);
      document.addEventListener('mousedown', onLoginFocus, true);
      document.addEventListener('keydown', function(e){ if (window.__lhLogin && loginFields(e.target)) post({t:'loginHide'}); }, true);
      window.__lhFill = function(id, password){
        var f = window.__lhLogin; if (!f) return;
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        function put(el, v){
          if (!el || v === null) return;
          setter.call(el, v);   // 프레임워크가 값을 다시 덮지 않게 원래 setter 로 넣고 이벤트를 보낸다
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        put(f.user, id); put(f.pass, password);
      };
      var ticking = false;
      window.addEventListener('scroll', function(){
        if (window.__lhSyncing && Date.now() - window.__lhSyncing < 150) return;
        if (ticking) return; ticking = true;
        requestAnimationFrame(function(){
          ticking = false;
          var se = document.scrollingElement || document.documentElement;
          var mx = Math.max(1, se.scrollWidth - innerWidth), my = Math.max(1, se.scrollHeight - innerHeight);
          post({t:'scroll', x: Math.min(1, scrollX / mx), y: Math.min(1, scrollY / my)});
        });
      }, {passive: true});
    })();
    """

    // MARK: State → tab

    private func observe() {
        func watch<V>(_ key: KeyPath<FocusAwareWebView, V>) -> NSKeyValueObservation {
            webView.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncState() }
            }
        }
        observations = [watch(\.title), watch(\.url), watch(\.isLoading), watch(\.estimatedProgress),
                        watch(\.canGoBack), watch(\.canGoForward)]
    }

    private func syncState() {
        guard let tab else { return }
        if let title = webView.title, !title.isEmpty { tab.pageTitle = title }
        if let url = webView.url { tab.currentURL = url }
        tab.isLoading = webView.isLoading
        tab.progress = webView.estimatedProgress
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
    }

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["t"] as? String else { return }
        switch type {
        case "hover": tab?.hoverURL = dict["href"] as? String ?? ""
        case "scroll":
            if let x = dict["x"] as? Double, let y = dict["y"] as? Double { onScroll?(x, y) }
        case "login":
            if let x = dict["x"] as? Double, let y = dict["y"] as? Double,
               let w = dict["w"] as? Double, let h = dict["h"] as? Double {
                onLoginFocus?(CGRect(x: x, y: y, width: w, height: h))
            }
        case "loginHide": onLoginFocus?(nil)
        case "area":
            if let top = dict["top"] as? Double, let bottom = dict["bottom"] as? Double,
               let left = dict["left"] as? Double, let right = dict["right"] as? Double, bottom > top, right > left {
                onAreaSelected?(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            } else { onAreaSelected?(nil) }
        case "areaCancel":
            onAreaSelected?(nil)
            showRulerOverlay()
        case "guides":
            tab?.guidesX = dict["x"] as? [Double] ?? []
            tab?.guidesY = dict["y"] as? [Double] ?? []
        default: break
        }
    }
}

// MARK: - Delegates

extension WebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await refreshCookieCount() }
        showRulerOverlay()   // 룰러 모드면 새 페이지에도 다시 띄운다
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onAreaSelected?(nil)   // 페이지가 바뀌면 영역 선택 오버레이도 사라진다
        onLoginFocus?(nil)
        tab?.loadError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// 링크 ⌘클릭 → 같은 묶음의 새 탭
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            _ = onOpenWindow?(nil, url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }   // <a download> 등
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // 사용자가 중지했거나 다른 이동으로 취소된 경우는 무시
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // 표시할 수 없는 응답을 우리가 취소한 경우 (안내는 decidePolicyFor 에서)
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        tab?.loadError = ns.localizedDescription
    }

    /// 첨부 파일(Content-Disposition: attachment)이나 표시할 수 없는 응답은 설정의 다운로드 폴더에 저장한다.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") || (navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType) {
            return .download
        }
        return .allow
    }
}

// MARK: - 다운로드

extension WebSession: WKDownloadDelegate {
    /// 진행 중인 다운로드를 붙들어 둔다 (WebKit 은 약하게만 잡는다)
    fileprivate func track(_ download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (download, "")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = AppSettings.downloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = AppSettings.uniqueURL(in: folder, name: suggestedFilename)
        downloads[ObjectIdentifier(download)] = (download, url.lastPathComponent)
        tab?.showNotice(String(localized: "Downloading: \(url.lastPathComponent)"))
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        let name = downloads.removeValue(forKey: ObjectIdentifier(download))?.name ?? ""
        tab?.showNotice(String(localized: "Downloaded: \(name)"))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let name = downloads.removeValue(forKey: ObjectIdentifier(download))?.name ?? ""
        tab?.showNotice(String(localized: "Download failed: \(name) (\(error.localizedDescription))"))
    }
}

extension WebSession: WKUIDelegate {
    /// target=_blank / window.open → 같은 묶음의 새 탭 (크기를 지정한 팝업도 탭으로)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        onOpenWindow?(configuration, navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? String(localized: "Alert")
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? String(localized: "Confirm")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// WKUserContentController 가 핸들러를 강하게 잡아서 생기는 순환 참조를 끊는다.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: WebSession?
    init(_ session: WebSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receive(message.body)
    }
}
