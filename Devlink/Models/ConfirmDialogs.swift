import AppKit

/// 네이티브 확인 창. "다시 묻지 않기" 값은 UserDefaults에 저장 (앱 설정 화면에서도 변경 예정).
enum ConfirmDialogs {
    static let skipClosePaneKey = "skipClosePaneConfirm"

    static func confirmClosePane(tabCount: Int) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: skipClosePaneKey) { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Close \(tabCount) tabs")
        alert.informativeText = String(localized: "Closing a split pane also closes its tabs. Move tabs you want to keep to the other side first.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: skipClosePaneKey)
        }
        return ok
    }

    /// 프로젝트 삭제 (되돌릴 수 없음)
    static func confirmDeleteProject(name: String, closingTabs: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete \(name)?")
        alert.informativeText = String(localized: "All environments, domains, URIs and accounts will be removed.")
            + (closingTabs > 0 ? "\n" + String(localized: "\(closingTabs) open tabs of this project will close.") : "")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 저장 안 한 설정 화면을 닫을 때 (탭·분할 화면·창 닫기, 종료)
    static func confirmDiscardSettings(count: Int) -> Bool {
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Close without saving?")
        alert.informativeText = count == 1
            ? String(localized: "Unsaved changes in project settings will be lost.")
            : String(localized: "Unsaved changes in \(count) project settings tabs will be lost.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    static let skipCloseTabsKey = "skipCloseTabsConfirm"

    /// 창 닫기·앱 종료: 웹 페이지 탭이 있으면 확인한다 (탭과 그 쿠키·저장소는 되살릴 수 없다).
    static func confirmCloseTabs(count: Int, quitting: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard count > 0, !defaults.bool(forKey: skipCloseTabsKey) else { return true }

        let alert = NSAlert()
        alert.messageText = quitting ? String(localized: "Quit and close \(count) tabs?") : String(localized: "Close \(count) tabs?")
        alert.informativeText = String(localized: "The cookies and storage of these tabs are deleted. Tabs are not restored.")
        alert.addButton(withTitle: quitting ? String(localized: "Quit") : String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: skipCloseTabsKey)
        }
        return ok
    }
}
