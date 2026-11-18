//
//  AboutCommands.swift
//  Devlink
//

import SwiftUI

/// 메뉴 > Devlink > About Devlink. 기본 About 창에 설명·저장소 링크·라이선스를 더한다
struct AboutCommands: Commands {
    static let repositoryURL = URL(string: "https://github.com/hobbieco/devlink")!

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Devlink") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
            }
        }
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let note: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: "A tab-based browser for development links — group links by project and environment.\n",
            attributes: body
        ))
        var link = body
        link[.link] = repositoryURL
        text.append(NSAttributedString(string: "github.com/hobbieco/devlink\n", attributes: link))
        text.append(NSAttributedString(
            string: "Licensed under the Apache License, Version 2.0.",
            attributes: note
        ))
        return text
    }
}
