import AppKit
import SwiftUI

/// 창을 닫기 전에 확인한다 (웹 페이지 탭이 있으면). 창의 delegate 앞에 끼우고, 나머지는 SwiftUI 의 원래 delegate 로 넘긴다.
struct WindowCloseGuard: NSViewRepresentable {
    let state: WindowState

    func makeNSView(context: Context) -> NSView { GuardView(state: state) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class GuardView: NSView {
        let state: WindowState
        private var proxy: Proxy?

        init(state: WindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private static let frameKey = "lastWindowFrame"

        /// 마지막으로 쓴 창 위치(모니터 포함)를 첫 창에 복원한다. 새 창(⌘N)은 시스템 배치를 따른다.
        private func restoreFrame(_ window: NSWindow) {
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.canBecomeMain }
            if others.isEmpty, let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
                window.setFrame(from: saved)
            }
            let center = NotificationCenter.default
            let key = Self.frameKey
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                // queue: .main 이라 메인 액터에서 불린다 (클로저가 Sendable 이라 컴파일러에 알려 준다)
                center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        UserDefaults.standard.set(window.frameDescriptor, forKey: key)
                    }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI 가 창 delegate 를 넣은 뒤에 끼운다
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.proxy == nil else { return }
                self.state.window = window
                self.restoreFrame(window)
                let proxy = Proxy(state: self.state, original: window.delegate)
                self.proxy = proxy
                window.delegate = proxy
            }
        }
    }

    private final class Proxy: NSObject, NSWindowDelegate {
        let state: WindowState
        nonisolated(unsafe) weak var original: NSWindowDelegate?   // 메인 스레드에서만 쓴다

        init(state: WindowState, original: NSWindowDelegate?) {
            self.state = state
            self.original = original
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if original?.windowShouldClose?(sender) == false { return false }
            return ConfirmDialogs.confirmDiscardSettings(count: state.unsavedSettingsCount)
                && ConfirmDialogs.confirmCloseTabs(count: state.pageTabCount, quitting: false)
        }
    }
}
