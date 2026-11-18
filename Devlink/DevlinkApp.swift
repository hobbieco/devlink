import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // 종료 전에 열려 있던 창을 모두 복원하지 않고, 재실행하면 창 하나만 연다 (위치는 WindowCloseGuard 가 복원).
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 앱 자체 탭을 쓰므로 macOS 창 탭(Show Tab Bar, Merge All Windows 등)은 끈다.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DataStores.removeLegacyStores()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 종료: 열려 있는 창의 웹 페이지 탭이 있으면 확인한다 (창 닫기에서 이미 확인한 창은 보이지 않으므로 빠진다).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let open = WindowState.all.allObjects.filter { $0.window?.isVisible == true }
        let unsaved = open.reduce(0) { $0 + $1.unsavedSettingsCount }
        let count = open.reduce(0) { $0 + $1.pageTabCount }
        return ConfirmDialogs.confirmDiscardSettings(count: unsaved) && ConfirmDialogs.confirmCloseTabs(count: count, quitting: true)
            ? .terminateNow : .terminateCancel
    }
}

@main
struct DevlinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.windowState) private var windowState
    @AppStorage("statusBarVisible") private var statusBarVisible = true

    var body: some Scene {
        WindowGroup("devlink") {
            MainView()
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AboutCommands()
            // 파일: 새 창(⌘N)은 WindowGroup 기본 제공
            CommandGroup(after: .newItem) {
                Button("New Tab") { windowState?.focusedPane?.addTab() }
                    .keyboardShortcut("t")
                Button("Close Tab") {
                    if let state = windowState, let pane = state.focusedPane, let id = pane.selectedTabID { state.closeTab(id, in: pane) }
                }
                .keyboardShortcut("w")
            }
            CommandGroup(replacing: .importExport) {
                Button("Import Project…") { ProjectTransfer.importFile() }
                Button("Export Projects…") { ProjectTransfer.exportSelected() }
            }
            // 편집: 복사/붙여넣기/찾기는 시스템 기본 + 추후 웹뷰 연결
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { zoom(by: 0.1) }.keyboardShortcut("+")
                Button("Zoom Out") { zoom(by: -0.1) }.keyboardShortcut("-")
                Button("Actual Size") { windowState?.focusedPane?.selectedTab?.zoom = 1 }.keyboardShortcut("0")
                Divider()
                Button(windowState?.isSplit == true ? String(localized: "Unsplit") : String(localized: "Split View")) { windowState?.toggleSplit() }
                    .keyboardShortcut("d")
                Button(windowState?.scrollSync == true ? String(localized: "Stop Scroll Sync") : String(localized: "Sync Scrolling")) {
                    windowState?.scrollSync.toggle()
                }
                .disabled(windowState?.isSplit != true)
                .keyboardShortcut("d", modifiers: [.command, .option])
                Menu("Compare with Env") {
                    ForEach(windowState?.compareTargets ?? []) { env in
                        Button(env.name) { windowState?.compareActiveTab(with: env) }
                    }
                }
                .disabled((windowState?.compareTargets ?? []).isEmpty)
                Button("Developer Tools") {
                    windowState?.focusedPane?.selectedTab?.session?.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button(statusBarVisible ? String(localized: "Hide Status Bar") : String(localized: "Show Status Bar")) { statusBarVisible.toggle() }
                    .keyboardShortcut("/")
                Divider()
                Button("Clear This Tab's Site Data") {
                    if let state = windowState, let tab = state.focusedPane?.selectedTab { state.clearStorage(tab, .all) }
                }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Capture") {
                let tab = windowState?.focusedPane?.selectedTab
                Button("Capture Full Page") { if let tab { windowState?.captureFullPage(tab) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(tab == nil || tab?.isCapturing == true)
                Button("Capture Area") { if let tab { windowState?.captureArea(tab) } }   // 선택 중에 다시 누르면 취소 (캡처는 페이지의 Capture 버튼)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(tab == nil || tab?.isCapturing == true)
                Button(tab?.isRulerOn == true ? String(localized: "Hide Rulers") : String(localized: "Show Rulers")) {
                    if let tab { windowState?.toggleRuler(tab) }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(tab == nil || tab?.isCapturing == true || tab?.isSelectingArea == true)
            }
        }
        Settings { SettingsView() }
    }

    private func zoom(by delta: Double) {
        guard let tab = windowState?.focusedPane?.selectedTab else { return }
        tab.zoom = min(3, max(0.3, tab.zoom + delta))
    }
}
