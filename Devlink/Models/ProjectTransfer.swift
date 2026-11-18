import AppKit
import UniformTypeIdentifiers

/// 프로젝트 내보내기(프로젝트 설정 화면 · 파일 메뉴) · 가져오기(파일 메뉴). 형식은 ProjectJSON. Default 와 비밀번호는 들어가지 않는다.
enum ProjectTransfer {
    /// 파일 메뉴: 체크 목록에서 고른 프로젝트들 (처음엔 모두 해제. Default 제외, closed 포함)
    static func exportSelected() {
        let candidates = ProjectLibrary.shared.projects.filter { !$0.isDefault }
        guard !candidates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Export projects")
        alert.informativeText = String(localized: "Choose the projects to export. Locked accounts are not exported.")
        let handler = CheckHandler()
        let boxes = candidates.map { p -> NSButton in
            let box = NSButton(checkboxWithTitle: p.name, target: handler, action: #selector(CheckHandler.changed))
            box.state = .off
            box.font = .systemFont(ofSize: 15)
            return box
        }
        // 상태 아이콘 칸 (고정 📌 · closed 🔒 · 일반은 빈칸). 칸 폭을 고정해 이름이 세로로 정렬된다
        let rows = zip(candidates, boxes).map { p, box -> NSStackView in
            let icon = NSTextField(labelWithString: p.closed ? "🔒" : p.pinned ? "📌" : "")
            icon.font = .systemFont(ofSize: 15)
            icon.alignment = .center
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let row = NSStackView(views: [icon, box])
            row.orientation = .horizontal
            row.spacing = 4
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // 목록 높이: 앱 창 높이의 80% 안에서 (알림창의 제목·설명·버튼 몫 130 제외), 넘으면 스크롤
        let content = CGFloat(boxes.count) * 28 + 4
        let windowHeight = NSApp.keyWindow?.frame.height ?? NSScreen.main?.visibleFrame.height ?? 800
        let height = max(80, min(content, windowHeight * 0.8 - 130))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        scroll.hasVerticalScroller = content > height
        scroll.drawsBackground = false
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: content)
        scroll.documentView = stack
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "Export"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].isEnabled = false
        handler.onChange = { alert.buttons[0].isEnabled = boxes.contains { $0.state == .on } }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        export(zip(candidates, boxes).filter { $1.state == .on }.map(\.0))
    }

    /// 폴더를 고르고, 같은 이름의 파일이 있으면 쓰기 전에 알려서 바꿀지(Replace) 중지할지 묻는다.
    static func export(_ projects: [Project]) {
        let list = projects.filter { !$0.isDefault }
        guard !list.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let files = list.map { (name: fileName($0.name), project: $0) }
        let taken = files.map(\.name).filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if !taken.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Files already exist")
            alert.informativeText = taken.joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for file in files {
            do {
                try ProjectJSON.encode([withoutLocked(file.project)]).write(to: dir.appendingPathComponent(file.name), options: .atomic)
            } catch {
                notify(String(localized: "Couldn't export"), error.localizedDescription)
                return
            }
        }
    }

    /// 잠근 계정은 내보내지 않는다 (아이디·이름도 밖으로 나가지 않는다)
    private static func withoutLocked(_ project: Project) -> Project {
        var p = project
        for e in p.envs.indices {
            for d in p.envs[e].domains.indices {
                let id = p.envs[e].domains[d].id
                p.envs[e].domains[d].accounts.removeAll { PasswordStore.shared.isLocked(domain: id, account: $0.login) }
            }
        }
        return p
    }

    /// 파일 이름에 못 쓰는 문자는 - 로 바꾼다
    private static func fileName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-") + ".json"
    }

    private static func iconImage(_ emoji: String) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            (emoji as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            return true
        }
    }

    private final class CheckHandler: NSObject {
        var onChange: (() -> Void)?
        @objc func changed() { onChange?() }
    }

    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        if panel.urls.count > 1 { importMany(panel.urls); return }
        // 프로젝트 하나짜리 파일만 받는다
        guard let data = try? Data(contentsOf: url), let decoded = ProjectJSON.decode(data), decoded.projects.count == 1 else {
            notify(String(localized: "Couldn't import"), String(localized: "This file is not a devlink project file."))
            return
        }
        let library = ProjectLibrary.shared
        let targets = library.importTargets

        // 새 프로젝트로 넣을지, 기존 프로젝트 맨 뒤에 붙일지
        let alert = NSAlert()
        alert.messageText = String(localized: "Import project")
        alert.informativeText = String(localized: "Add as a new project, or append its environments to an existing one.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        popup.font = .systemFont(ofSize: 15)
        popup.addItem(withTitle: String(localized: "New project"))
        popup.menu?.addItem(.separator())
        popup.addItems(withTitles: targets.map(\.name))
        // 아이콘 칸: 고정 📌, 나머지는 같은 크기의 빈 이미지 (이미지가 없는 항목은 칸을 차지하지 않아 정렬이 깨진다)
        for (i, item) in (popup.menu?.items ?? []).enumerated() where !item.isSeparatorItem {
            item.image = iconImage(i >= 2 && targets[i - 2].pinned ? "📌" : "")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 구분선 칸은 목록 번호에 없다: 0 = 새 프로젝트, 2부터 targets[0]
        let index = popup.indexOfSelectedItem
        let target = index >= 2 ? targets[index - 2].id : nil
        if let name = library.importProject(decoded.projects[0], into: target) {
            notify(String(localized: "Imported"), name)
        }
    }

    /// 파일이 여럿이면 묻지 않고 모두 새 프로젝트로 (선택 순서대로 일반 영역 맨 뒤에).
    /// 형식이 맞지 않는 파일은 건너뛰고 마지막에 결과를 알린다.
    private static func importMany(_ urls: [URL]) {
        var imported = 0
        var failed: [String] = []
        for url in urls {
            if let data = try? Data(contentsOf: url), let decoded = ProjectJSON.decode(data), decoded.projects.count == 1,
               ProjectLibrary.shared.importProject(decoded.projects[0], into: nil) != nil {
                imported += 1
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        var detail = String(localized: "\(imported) imported")
        if !failed.isEmpty {
            detail += "\n" + String(localized: "\(failed.count) failed") + ": " + failed.joined(separator: ", ")
        }
        notify(String(localized: "Imported"), detail)
    }

    private static func notify(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
