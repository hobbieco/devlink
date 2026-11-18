import AppKit
import SwiftUI

/// 앱 전체 설정 창 (⌘,)
struct SettingsView: View {
    @AppStorage(AppSettings.guideColorKey) private var guideColor = GuideColor.red.rawValue
    @AppStorage(AppSettings.captureColorKey) private var captureColor = GuideColor.blue.rawValue
    @AppStorage(AppSettings.screenshotFolderKey) private var screenshotFolder = ""
    @AppStorage(AppSettings.downloadFolderKey) private var downloadFolder = ""

    var body: some View {
        Form {
            Section("Line Colors") {
                colorPicker("Guide lines", selection: $guideColor)
                colorPicker("Screenshot area lines", selection: $captureColor)
            }
            Section("Save Locations") {
                FolderRow(title: "Screenshots", path: $screenshotFolder)
                FolderRow(title: "Downloads", path: $downloadFolder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func colorPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(GuideColor.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

/// 저장 폴더 한 줄: 현재 폴더, 선택, 기본(~/Downloads)으로 되돌리기
private struct FolderRow: View {
    let title: LocalizedStringKey
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(((path.isEmpty ? AppSettings.defaultFolder.path : path) as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { choose() }
                Button("Reset") { path = "" }.disabled(path.isEmpty)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = path.isEmpty ? AppSettings.defaultFolder : URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
