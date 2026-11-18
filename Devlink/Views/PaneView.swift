import SwiftUI
import UniformTypeIdentifiers
import WebKit
import SecurityInterface

/// 브라우징 영역 하나 (분할 시 2개). 탭 목록·도구·개발자 도구를 각각 가진다.
struct PaneView: View {
    let state: WindowState
    let pane: Pane
    @AppStorage("statusBarVisible") private var statusBarVisible = true

    private var isFocused: Bool { state.isSplit && state.focusedPaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(state: state, pane: pane)
            Divider()
            VStack(spacing: 0) {
            if let tab = pane.selectedTab {
                switch tab.content {
                case .start(let route):
                    StartPageView(state: state, tab: tab, route: route)
                case .page(let pid, let eid, let path):
                    BrowserToolbarView(state: state, pane: pane, tab: tab, projectID: pid, envID: eid, path: path)
                    Divider()
                    browsingArea(tab: tab, path: path)
                }
                if statusBarVisible {
                    Divider()
                    StatusBarView(state: state, pane: pane, tab: tab)
                }
            }
            }
            .overlay {
                // 탭 드래그 중에만: 웹 영역·주소창 대신 드롭을 받는다 (분할 / 반대쪽 화면으로 이동)
                if state.drag.isDragging {
                    ContentDropOverlay(state: state, drag: state.drag, pane: pane)
                }
            }
        }
        .overlay {
            if isFocused {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { state.focusedPaneID = pane.id })
    }

    private func browsingArea(tab: BrowserTab, path: String) -> some View {
        WebContentView(state: state, tab: tab)
            .overlay {
                // 스크린샷을 찍는 동안: 웹 영역에 음영 + 가운데 카메라 (찍히는 이미지에는 들어가지 않는다)
                if tab.isCapturing {
                    ZStack {
                        Color.black.opacity(0.45)
                        VStack(spacing: 10) {
                            Image(systemName: "camera.fill").font(.system(size: 44))
                            Text("Capturing…").font(.headline)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
    }
}

// MARK: - ② 탭 목록

struct TabBarView: View {
    let state: WindowState
    let pane: Pane
    @State private var showList = false

    var body: some View {
        HStack(spacing: 6) {
            Button { showList.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    Text("\(pane.tabs.count)").font(UIMetrics.font.monospacedDigit())
                }
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .help("Tab list")
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                TabListPopover(state: state, pane: pane) { showList = false }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(pane.groups) { group in
                            HStack(spacing: 2) {
                                ForEach(group.tabs) { tab in tabItem(tab, grouped: group.tabs.count > 1) }
                            }
                            .padding(2)
                            .overlay {
                                // 묶음(쿠키를 함께 쓰는 탭들)은 외곽선 하나로 감싼다
                                if group.tabs.count > 1 {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 40)   // 마지막 탭 뒤 빈 곳도 드롭 영역
                }
                .onChange(of: pane.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear { if let id = pane.selectedTabID { proxy.scrollTo(id) } }
            }
            Button { pane.addTab() } label: { Image(systemName: "plus").font(.system(size: 13)) }
                .buttonStyle(.borderless)
                .help("New Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)   // 묶음 외곽선 자리(2pt)를 탭마다 두므로 그만큼 줄인다
        .background(.bar)
        .onDrop(of: [.devlinkTab], delegate: TabBarDropDelegate(state: state, drag: state.drag, pane: pane))
    }

    /// 탭 하나. 묶음 안의 탭은 × 를 항상 보인다 (묶음 닫기는 없다). 드래그는 묶음째로.
    private func tabItem(_ tab: BrowserTab, grouped: Bool) -> some View {
        TabItemView(
            title: state.title(of: tab),
            color: state.envColor(of: tab),
            projectColor: state.projectColor(of: tab),
            selected: tab.id == pane.selectedTabID,
            paneActive: !state.isSplit || state.focusedPaneID == pane.id,
            alwaysShowClose: grouped,
            onSelect: { pane.selectedTabID = tab.id },
            onClose: { state.closeTab(tab.id, in: pane) }
        )
        .id(tab.id)
        .opacity(state.drag.groupID == tab.groupID ? 0.4 : 1)
        .onDrag {
            state.drag.begin(tab: tab.id, group: tab.groupID, pane: pane.id)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.devlinkTab.identifier,
                                                visibility: .ownProcess) { done in
                done(Data(tab.id.uuidString.utf8), nil)
                return nil
            }
            return provider
        } preview: {
            TabItemView(title: state.title(of: tab), color: state.envColor(of: tab),
                        projectColor: state.projectColor(of: tab), selected: true, onSelect: {}, onClose: {})
        }
        .onDrop(of: [.devlinkTab],
                delegate: TabItemDropDelegate(state: state, drag: state.drag, pane: pane, target: tab))
    }
}

/// 탭 전체 목록. 선택된 탭은 진하게. 묶음은 첫 탭이 1단, 나머지는 그 아래에 들여 쓴다.
struct TabListPopover: View {
    let state: WindowState
    let pane: Pane
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(pane.groups) { group in
                    ForEach(group.tabs) { tab in
                        TabListRow(
                            title: state.title(of: tab),
                            color: state.envColor(of: tab),
                            selected: tab.id == pane.selectedTabID,
                            indented: tab.id != group.tabs[0].id,
                            onSelect: { pane.selectedTabID = tab.id; dismiss() },
                            onClose: { state.closeTab(tab.id, in: pane) }
                        )
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 340)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TabListRow: View {
    let title: String
    let color: Color?
    let selected: Bool
    /// 묶음의 둘째 탭부터 (첫 탭 아래에 들여 쓴다)
    var indented = false
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if indented { Color.clear.frame(width: 14, height: 1) }
            Circle().fill(color ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(title)
                .font(UIMetrics.font)
                .fontWeight(selected ? .bold : .regular)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

struct TabItemView: View {
    let title: String
    let color: Color?
    /// 프로젝트 색: 탭 아래 띠 (없으면 띠도 구분선도 없다)
    var projectColor: Color? = nil
    let selected: Bool
    /// 분할 상태에서 이 화면이 포커스인지 (포커스 아닌 화면은 선택 탭을 조금 흐리게)
    var paneActive = true
    /// 묶음 안의 탭: × 를 항상 보인다
    var alwaysShowClose = false
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    /// 환경 탭: 환경 색 배경 (비활성 흐리게, 활성 100%) + 흰 글자. 새 탭: 회색 면.
    private var fill: Color {
        let color = self.color ?? EnvPalette.noEnv.color   // 환경 없는 탭은 고정 회색
        if selected { return color.opacity(paneActive ? 1 : 0.7) }
        return color.opacity(hovering ? 0.6 : 0.45)
    }

    private var textColor: Color {
        return selected ? .white : .white.opacity(0.85)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.tail).font(UIMetrics.font)
                .foregroundStyle(textColor)
                .fontWeight(selected ? .semibold : .regular)
            Spacer(minLength: 4)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption2).foregroundStyle(textColor) }
                .buttonStyle(.borderless)
                .opacity(hovering || selected || alwaysShowClose ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 10)   // 아래 4pt 는 프로젝트 색 띠 자리. 색이 없어도 같은 높이
        .frame(width: 200, height: 33, alignment: .top)   // 높이를 정수로 고정: 글꼴 높이(소수) 때문에 띠 위치가 화면 픽셀에 어긋나는 것을 막는다
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(alignment: .bottom) {
            if let projectColor {
                Rectangle().fill(projectColor).frame(height: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - ⑤ 브라우징 도구 + 주소창

struct BrowserToolbarView: View {
    let state: WindowState
    let pane: Pane
    let tab: BrowserTab
    let projectID: UUID
    let envID: UUID
    let path: String
    @State private var address = ""

    @State private var cert: CertificateInfo?

    /// 주소 왼쪽 자물쇠: https = 누르면 시스템 인증서 창 (만료 25일 이하 주황 · 15일 이하 빨강 + 남은 일수), http = 빨간 사선 자물쇠, 그 밖의 주소는 없음
    @ViewBuilder private var lockButton: some View {
        switch tab.currentURL?.scheme?.lowercased() {
        case "https":
            let color: Color = switch cert?.level { case .warning: .orange; case .critical: .red; default: .secondary }
            Button(action: showCertificate) {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    if let badge = cert?.badge { Text(badge).font(.caption) }
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.borderless)
            .disabled(cert == nil)
            .help(cert?.tooltip ?? String(localized: "Certificate not available"))
        case "http":
            Image(systemName: "lock.slash").foregroundStyle(.red)
                .help(String(localized: "Not secure (http)"))
        default:
            EmptyView()
        }
    }

    private func refreshCertificate() { cert = CertificateInfo(webView: tab.session?.webView) }

    private func showCertificate() {
        guard let cert else { return }
        SFCertificatePanel.shared().beginSheet(for: tab.session?.webView.window, modalDelegate: nil, didEnd: nil,
                                              contextInfo: nil, certificates: cert.chain, showGroup: true)
    }

    @State private var showCustomWidth = false
    @State private var customWidthText = ""

    /// 모바일 보기 폭 선택 (nil 이면 끔). 켜고 끌 때만 User-Agent 를 바꿔 다시 로드한다.
    private func setMobile(_ width: CGFloat?) {
        let changedMode = (tab.mobileWidth == nil) != (width == nil)
        tab.mobileWidth = width
        tab.session?.setMobile(width, reload: changedMode)
    }

    private func setUserAgent(_ preset: UserAgentPreset?) {
        tab.userAgent = preset
        tab.session?.applyUserAgent()
    }

    private func applyCustomWidth() {
        showCustomWidth = false
        guard let value = Double(customWidthText.trimmingCharacters(in: .whitespaces)) else { return }
        setMobile(CGFloat(min(max(value.rounded(), 200), 1200)))
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                Button { session?.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack).help("Back")
                Button { session?.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward).help("Forward")
                if tab.isLoading {
                    Button { session?.webView.stopLoading() } label: { Image(systemName: "xmark") }.help("Stop")
                } else {
                    Menu {
                        Button("Reload") { session?.reload(hard: false) }
                        Button("Hard Reload (Ignore Cache)") { session?.reload(hard: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    } primaryAction: { session?.reload(hard: false) }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Reload (hold for hard reload)")
                }
                Button { state.goHome(tab) } label: { Image(systemName: "house") }.help("Home: the first link opened in this tab")
            }
            .buttonStyle(.borderless)

            lockButton

            TextField("Address", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(UIMetrics.font)
                .onSubmit(go)
                .onAppear { address = tab.currentURL?.absoluteString ?? ""; refreshCertificate() }
                .onChange(of: tab.currentURL) { address = tab.currentURL?.absoluteString ?? ""; refreshCertificate() }
                .onChange(of: tab.isLoading) { refreshCertificate() }   // 불러오기가 끝나면 그 페이지의 인증서

            Group {
                Menu {
                    Button("Capture from Left Edge") { state.captureFullPage(tab) }
                    Button("Capture Visible Width Only") { state.captureFullPage(tab, visibleWidthOnly: true) }
                } label: {
                    ToggleIcon(name: "camera", on: false)
                } primaryAction: { state.captureFullPage(tab) }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(tab.isCapturing)
                    .help("Save a full-page screenshot to Downloads (from the left edge to the right edge of the view, hold to choose)")
                Button { state.captureArea(tab) } label: {
                    ToggleIcon(name: "crop", on: tab.isSelectingArea)
                }
                .disabled(tab.isCapturing)
                .help("Screenshot of an area: drag the lines (pull the top and left lines out of the rulers), then capture")
                Menu {
                    ForEach(GuideColor.allCases) { color in
                        Button {
                            state.setGuideColor(tab, color)
                        } label: {
                            // 글자 없이 이미지만 두면 메뉴가 항목을 그리지 않는다 → 제목이 있는 Label 을 아이콘만 보이게
                            Label { Text(color.title) } icon: { Image(nsImage: color.swatch(selected: tab.guideColor == color)) }
                                .labelStyle(.iconOnly)
                        }
                    }
                } label: {
                    ToggleIcon(name: "ruler", on: tab.isRulerOn)
                } primaryAction: { state.toggleRuler(tab) }
                    .id(tab.guideColor)   // 색이 바뀌면 메뉴를 다시 만든다 (안 그러면 선택 표시가 처음 색에 머문다)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(tab.isCapturing || tab.isSelectingArea)
                    .help("Rulers and guides: drag from a ruler to add a guide, drag it back to remove, click the corner to clear all (hold to choose the guide color)")
                Menu {
                    Button("Off") { setMobile(nil) }
                    Divider()
                    ForEach(MobileDevice.allCases) { device in
                        Button {
                            setMobile(device.width)
                        } label: {
                            if tab.mobileWidth == device.width { Image(systemName: "checkmark") }
                            Text("\(device.rawValue)  \(Int(device.width)) px")
                        }
                    }
                    Divider()
                    Button {
                        customWidthText = String(Int(tab.mobileWidth ?? 390))
                        showCustomWidth = true
                    } label: {
                        if let w = tab.mobileWidth, !MobileDevice.allCases.contains(where: { $0.width == w }) {
                            Image(systemName: "checkmark")
                            Text("Custom Width…  \(Int(w)) px")
                        } else {
                            Text("Custom Width…")
                        }
                    }
                } label: {
                    ToggleIcon(name: "iphone", on: tab.mobileWidth != nil)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mobile view")
                .popover(isPresented: $showCustomWidth) {
                    HStack {
                        TextField("Width", text: $customWidthText)
                            .frame(width: 70)
                            .onSubmit(applyCustomWidth)
                        Text("px").foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                Menu {
                    Button {
                        setUserAgent(nil)
                    } label: {
                        if tab.userAgent == nil { Image(systemName: "checkmark") }
                        Text("Default")
                    }
                    Divider()
                    ForEach(UserAgentPreset.allCases) { preset in
                        Button {
                            setUserAgent(preset)
                        } label: {
                            if tab.userAgent == preset { Image(systemName: "checkmark") }
                            Text(preset.rawValue)
                        }
                    }
                } label: {
                    ToggleIcon(name: "person.text.rectangle", on: tab.userAgent != nil, weight: .bold)   // 안쪽 칸이 흐려 보여서 굵게
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("User Agent: \(tab.userAgent?.rawValue ?? String(localized: "Default"))")
                Menu {
                    ClearMenuItems(state: state, tab: tab)
                } label: {
                    ToggleIcon(name: "trash", on: false)
                } primaryAction: { state.clearStorage(tab, .all) }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Clear all site data for this tab and reload (hold to choose)")
                Button {
                    tab.session?.toggleInspector()
                } label: {
                    // 인스펙터 자체의 닫기 버튼으로 닫을 수도 있어 주기적으로 상태를 읽는다
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ToggleIcon(name: "hammer", on: tab.session?.isInspectorOpen == true)
                    }
                }
                .help("Developer Tools")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Enter: 항상 현재 탭(같은 저장소)에서 이동. 방문 상태는 상태 표시줄이 판정.
    private func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
            text = (local ? "http://" : "https://") + text
        }
        if let url = URL(string: text) { state.navigate(tab, to: url) }
    }

    private var session: WebSession? { tab.session }
}

/// 쿠키·저장소 삭제 메뉴 항목 (툴바 휴지통, 상태 표시줄 공용)
struct ClearMenuItems: View {
    let state: WindowState
    let tab: BrowserTab

    var body: some View {
        Button(ClearKind.all.title) { state.clearStorage(tab, .all) }
        Divider()
        ForEach([ClearKind.cookies, .storage, .cache], id: \.self) { kind in
            Button(kind.title) { state.clearStorage(tab, kind) }
        }
    }
}

// MARK: - ④ 브라우징 화면

struct WebContentView: View {
    let state: WindowState
    let tab: BrowserTab

    var body: some View {
        if let session = state.session(for: tab) {
            WebViewHost(webView: session.webView, zoom: tab.zoom, mobileWidth: tab.mobileWidth)
                .id(tab.id)
                .overlay {
                    if let error = tab.loadError {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("Can't open this page").font(.title3.weight(.semibold))
                            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Text(tab.currentURL?.absoluteString ?? "").font(.callout).foregroundStyle(.tertiary)
                            Button("Try Again") { session.reload(hard: false) }.padding(.top, 4)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}

/// 주소표시줄 아이콘: 꺼짐은 기본색, 켜짐은 강조색 + 연한 배경 (배경은 자리를 차지하지 않는다).
/// 색을 입힌 이미지로 그린다: primaryAction 이 있는 메뉴는 일반 아이콘의 색을 무시하고 흐리게 그리기 때문이다.
private struct ToggleIcon: View {
    let name: String
    let on: Bool
    var weight: NSFont.Weight = .regular

    private var image: NSImage {
        let color: NSColor = on ? .controlAccentColor : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: weight)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    var body: some View {
        Image(nsImage: image)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.18) : .clear))
            .padding(-3)
    }
}
