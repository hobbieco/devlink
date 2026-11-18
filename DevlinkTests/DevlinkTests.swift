import Foundation
import Testing
@testable import Devlink

@MainActor
struct DevlinkTests {
    @Test func newPaneStartsWithOneTab() {
        let pane = Pane()
        #expect(pane.tabs.count == 1)
        #expect(pane.selectedTabID == pane.tabs.first?.id)
    }

    @Test func visitStatus() {
        let state = WindowState()
        let shop = state.projects.first { $0.name == "Sample Shop" }!
        let prod = shop.envs[3]
        let tab = state.makePageTab(project: shop, env: prod, path: "/")
        #expect(state.visitStatus(of: tab) == .sameEnv)

        tab.currentURL = URL(string: "https://sso.example.net/auth")   // prod 의 다른 도메인
        #expect(state.visitStatus(of: tab) == .sameEnv)

        tab.currentURL = URL(string: "http://localhost:8080/")         // local 의 두 번째 포트
        #expect(state.visitStatus(of: tab) == .otherEnv(project: "Sample Shop", env: "LOCAL"))

        tab.currentURL = URL(string: "http://localhost:9999/")
        #expect(state.visitStatus(of: tab) == .external)

        tab.currentURL = URL(string: "https://admin.example.org/")     // 다른 프로젝트
        #expect(state.visitStatus(of: tab) == .otherEnv(project: "Admin Console", env: "PRD"))
    }

    @Test func compareOpensInOtherPaneAndSplits() {
        let state = WindowState()
        let shop = state.projects.first { $0.name == "Sample Shop" }!
        let pane = state.panes[0]
        let tab = state.makePageTab(project: shop, env: shop.envs[1], path: "/products")
        tab.currentURL = URL(string: "https://dev.example.com/products?id=3")
        pane.add(tab)

        state.openCompare(from: tab, in: pane, env: shop.envs[3])
        #expect(state.panes.count == 2)
        let opened = state.panes[1].selectedTab
        #expect(opened?.currentURL?.absoluteString == "https://www.example.com/products?id=3")
        #expect(state.focusedPaneID == state.panes[1].id)
    }
}

@MainActor
struct TabDragTests {
    private func stateWithTabs(_ n: Int) -> (WindowState, Pane) {
        let state = WindowState()
        let pane = state.panes[0]
        for _ in 1..<n { pane.addTab() }
        return (state, pane)
    }

    @Test func reorderWithinPane() {
        let (state, pane) = stateWithTabs(3)
        let ids = pane.tabs.map(\.id)
        state.reorder(ids[0], to: ids[2], in: pane)
        #expect(pane.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func dropOnContentSplitsToRight() {
        let (state, pane) = stateWithTabs(2)
        let moved = pane.tabs[1].id
        #expect(state.canDropOnContent(of: pane, dragged: moved))
        state.dropOnContent(of: pane, dragged: moved)
        #expect(state.panes.count == 2)
        #expect(state.panes[1].tabs.map(\.id) == [moved])
        #expect(state.panes[0].tabs.count == 1)
        #expect(state.splitRatio == 0.5)
    }

    @Test func singleTabCannotSplitItself() {
        let (state, pane) = stateWithTabs(1)
        #expect(!state.canDropOnContent(of: pane, dragged: pane.tabs[0].id))
    }

    /// 탭 3개 중 가운데 탭에서 파생 탭 2개: [a, b, b1, b2, c]
    private func stateWithGroup() -> (WindowState, Pane, [BrowserTab]) {
        let (state, pane) = stateWithTabs(3)
        let b = pane.tabs[1]
        let b1 = BrowserTab(), b2 = BrowserTab()
        pane.addDerived(b1, from: b)
        pane.addDerived(b2, from: b1)   // 파생 탭에서 다시 파생해도 같은 묶음의 맨 끝
        return (state, pane, [pane.tabs[0], b, b1, b2, pane.tabs[4]])
    }

    @Test func derivedTabsJoinGroupAtEnd() {
        let (_, pane, t) = stateWithGroup()
        #expect(pane.tabs.map(\.id) == t.map(\.id))
        #expect(pane.groups.map { $0.tabs.count } == [1, 3, 1])
        #expect(t[3].groupID == t[1].id && pane.selectedTabID == t[3].id)
        // 묶음이 선택된 상태에서 새 독립 탭은 묶음 뒤에
        let n = BrowserTab()
        pane.insertAfterSelected(n)
        #expect(pane.tabs.map(\.id) == [t[0], t[1], t[2], t[3], n, t[4]].map(\.id))
        // 파생 탭을 닫으면 같은 묶음의 앞 탭, 첫 탭을 닫으면 다음 탭이 묶음의 첫 탭
        pane.selectedTabID = t[3].id
        pane.closeTab(t[3].id)
        #expect(pane.selectedTabID == t[2].id)
        pane.closeTab(t[1].id)
        #expect(pane.groups.map { $0.tabs.map(\.id) } == [[t[0].id], [t[2].id], [n.id], [t[4].id]])
    }

    @Test func groupMovesAsWhole() {
        let (state, pane, t) = stateWithGroup()
        // 묶음 안: 그 탭만 자리 이동
        state.reorder(t[1].id, to: t[2].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[0], t[2], t[1], t[3], t[4]].map(\.id))
        // 묶음 밖으로: 묶음째로 (다른 탭이 묶음 사이에 끼지 않는다)
        state.reorder(t[1].id, to: t[4].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[0], t[4], t[2], t[1], t[3]].map(\.id))
        // 묶음 중간 탭 위에서는 그대로, 묶음을 다 지난 쪽 끝 탭 위에서 옮긴다
        state.reorder(t[0].id, to: t[2].id, in: pane)
        state.reorder(t[0].id, to: t[1].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[0], t[4], t[2], t[1], t[3]].map(\.id))
        state.reorder(t[0].id, to: t[3].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[4], t[2], t[1], t[3], t[0]].map(\.id))
        state.reorder(t[0].id, to: t[3].id, in: pane)   // 왼쪽으로: 첫 탭이 아니면 그대로
        #expect(pane.tabs.map(\.id) == [t[4], t[2], t[1], t[3], t[0]].map(\.id))
        state.reorder(t[0].id, to: t[2].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[4], t[0], t[2], t[1], t[3]].map(\.id))
        state.reorder(t[0].id, to: t[3].id, in: pane)
        #expect(pane.tabs.map(\.id) == [t[4], t[2], t[1], t[3], t[0]].map(\.id))
        // 분할: 묶음째로 오른쪽 화면에
        state.dropOnContent(of: pane, dragged: t[3].id)
        #expect(state.panes[1].tabs.map(\.id) == [t[2], t[1], t[3]].map(\.id))
        #expect(state.panes[1].selectedTabID == t[3].id)
        // 다른 화면의 묶음 가운데에 놓아도 묶음 앞으로
        state.move(t[0].id, to: state.panes[1], at: 1)
        #expect(state.panes[1].tabs.map(\.id) == [t[0], t[2], t[1], t[3]].map(\.id))
    }

    @Test func groupAloneCannotSplit() {
        let (state, pane) = stateWithTabs(1)
        pane.addDerived(BrowserTab(), from: pane.tabs[0])
        #expect(!state.canDropOnContent(of: pane, dragged: pane.tabs[1].id))
    }

    @Test func moveLastTabClosesSourcePane() {
        let (state, pane) = stateWithTabs(2)
        state.dropOnContent(of: pane, dragged: pane.tabs[1].id)   // split
        let right = state.panes[1]
        let left = state.panes[0]
        state.move(left.tabs[0].id, to: right, at: 0)
        #expect(state.panes.count == 1)
        #expect(state.panes[0] === right)
        #expect(right.tabs.count == 2)
    }
}

@MainActor
struct EnvPaletteTests {
    @Test func colorsAreFreeWithLegacyDefaults() {
        // 색을 지정하지 않으면 예전 표준 이름 색, 지정하면 그 색 (이름과 상관없이)
        #expect(ProjectEnv(name: "local").palette == .slate)
        #expect(ProjectEnv(name: "DEV").palette == .green)
        #expect(ProjectEnv(name: "prd", palette: .blue).palette == .blue)
        #expect(ProjectEnv(name: "gsc", palette: .teal).palette == .teal)
        #expect(EnvPalette.defaultColor(forIndex: 0) == .slate)
        #expect(EnvPalette.defaultColor(forIndex: 10) == .slate)
    }

    @Test func newProjectStartsWithLocalAndNextColor() {
        var p = Project.makeNew(name: "New", baseDomain: "example.com")
        #expect(p.envs.map(\.name) == ["LOCAL"])
        #expect(p.envs[0].palette == .slate)
        #expect(p.nextPalette() == .green)                // 색 순서대로
        p.envs.append(ProjectEnv(name: "DEV", palette: .green))
        #expect(p.nextPalette() == .mustard)
    }
}

@MainActor
struct ProjectLibraryTests {
    @Test func importAsNewOrAppend() throws {
        let lib = ProjectLibrary.shared
        let existing = try #require(lib.importTargets.first)
        let before = existing.envs.count
        // JSON 으로 내보냈다가 읽은 것을 가져온다
        let decoded = try #require(ProjectJSON.decode(ProjectJSON.encode([existing])))
        let src = decoded.projects[0]

        // 새 프로젝트: 새 id, 이름이 겹치면 번호
        let newName = try #require(lib.importProject(src, into: nil))
        let added = try #require(lib.projects.first { $0.name == newName })
        #expect(added.id != existing.id && newName != existing.name)
        #expect(!added.isDefault && !added.pinned && !added.closed)
        #expect(added.envs.map(\.id).allSatisfy { id in !src.envs.contains { $0.id == id } })   // 환경 id 도 새로

        // 기존 프로젝트: 환경이 맨 뒤에 붙고 id 는 새로
        _ = lib.importProject(src, into: existing.id)
        let after = try #require(lib.projects.first { $0.id == existing.id })
        #expect(after.envs.count == before * 2)
        #expect(after.envs.suffix(before).map(\.name) == src.envs.map(\.name))
        #expect(Set(after.envs.map(\.id)).count == after.envs.count)

        // Default·closed 는 대상이 아니다
        #expect(lib.importProject(src, into: lib.defaultProject?.id) == nil)

        lib.delete(added.id)
        lib.update(existing)   // 공유 상태 되돌림
    }

    @Test func passwordsPerDomainAccount() {
        let store = PasswordStore.shared
        let a = UUID(), b = UUID()
        store.set("pw1", domain: a, account: "admin")
        store.set("pw2", domain: b, account: "admin")
        #expect(store.password(domain: a, account: "admin") == "pw1")
        #expect(store.has(domain: b, account: "admin") && !store.has(domain: a, account: "user"))
        store.set("", domain: a, account: "admin")                       // 비우면 지움
        #expect(!store.has(domain: a, account: "admin"))
        store.prune(keeping: [])                                          // 없어진 계정 정리
        #expect(!store.has(domain: b, account: "admin"))
    }

    @Test func editedCarriesPasswords() {
        let base = Project.makeNew(name: "P", baseDomain: "x.com")
        let did = UUID()
        let data: [String: Any] = ["name": "P", "baseDomain": "x.com", "envs": [[
            "id": base.envs[0].id.uuidString, "name": "LOCAL",
            "domains": [["id": did.uuidString, "sub": "local.", "accounts": [
                ["id": " admin ", "name": " 관리자 ", "pw": "p w"], ["id": "", "pw": "x"], ["id": "guest", "pw": ""]]]]]]]
        var passwords: [String: String] = [:]
        let edited = Project(edited: data, base: base, passwords: &passwords)
        #expect(edited?.envs[0].domains[0].accounts.map(\.login) == ["admin", "guest"])   // 아이디가 빈 행은 버림
        #expect(edited?.envs[0].domains[0].accounts.map(\.name) == ["관리자", ""])
        if let edited, let db = try? ProjectDB.open(path: nil) {   // 이름은 DB 에도 남는다
            try? ProjectDB.save([edited], to: db)
            #expect((try? ProjectDB.load(db))?.first?.envs[0].domains[0].accounts.first?.name == "관리자")
        }
        #expect(passwords == [PasswordStore.itemKey(domain: did, account: "admin"): "p w",
                              PasswordStore.itemKey(domain: did, account: "guest"): ""])
        let store = PasswordStore.shared
        store.apply(passwords)
        #expect(store.passwords(domain: did, accounts: ["admin", "guest"]) == ["admin": "p w"])
        store.apply([PasswordStore.itemKey(domain: did, account: "admin"): ""])
        #expect(!store.has(domain: did, account: "admin"))
    }

    @Test func deleteKeepsDefault() {
        let lib = ProjectLibrary.shared
        let original = lib.projects
        defer { lib.projects = original }
        let target = lib.otherProjects[0].id
        lib.delete(target)
        #expect(!lib.projects.contains { $0.id == target })
        let def = lib.defaultProject!.id
        lib.delete(def)                                   // Default 는 지워지지 않는다
        #expect(lib.projects.contains { $0.id == def })
    }

    @Test func defaultFirstAndPinRules() {
        let lib = ProjectLibrary.shared
        let original = lib.projects
        defer { lib.projects = original }
        #expect(lib.projects.first?.isDefault == true)

        let others = lib.otherProjects.map(\.id)
        // 일반 → 고정 (영역을 넘는 드래그)
        lib.reorder(pinned: [others[0]], others: Array(others.dropFirst()))
        #expect(lib.pinnedProjects.map(\.id) == [others[0]])
        #expect(lib.projects.first?.isDefault == true)            // Default 는 항상 맨 앞
        // 고정 → 일반
        lib.reorder(pinned: [], others: others)
        #expect(lib.pinnedProjects.isEmpty)
        #expect(lib.otherProjects.map(\.id) == others)
    }

    @Test func closedAreaByDrag() {
        let lib = ProjectLibrary.shared
        let original = lib.projects
        defer { lib.projects = original }
        let others = lib.otherProjects.map(\.id)
        lib.reorder(pinned: [], others: Array(others.dropFirst()), closed: [others[0]])
        #expect(lib.closedProjects.map(\.id) == [others[0]])
        #expect(lib.projects.last?.id == others[0])                 // closed 는 맨 뒤
        lib.reorder(pinned: [], others: others, closed: [])
        #expect(lib.closedProjects.isEmpty)
    }

    @Test func createGoesFrontOfOthersWithUniqueName() {
        let lib = ProjectLibrary.shared
        let original = lib.projects
        defer { lib.projects = original }
        let a = lib.create(name: "")
        let b = lib.create(name: "  ")
        #expect(a.name == "New Project")
        #expect(b.name == "New Project 2")
        #expect(lib.otherProjects.first?.id == b.id)
        #expect(a.envs.map(\.name) == ["LOCAL"])
    }

    @Test func duplicateCopiesSelectedOnly() {
        let shop = SampleData.projects.first { $0.name == "Sample Shop" }!
        let copy = shop.duplicated(name: "Copy", domains: false, uris: true, accounts: false)
        #expect(copy.envs.map(\.name) == shop.envs.map(\.name))   // 환경은 모두
        // 도메인은 빼고 URI 만: 도메인 자리(이름)는 남고 host·계정은 비운다
        #expect(copy.baseDomain.isEmpty)
        #expect(copy.envs.allSatisfy { $0.domains.allSatisfy { $0.sub.isEmpty && $0.accounts.isEmpty } })
        #expect(copy.envs[1].domains.map { $0.uris.map(\.path) } == shop.envs[1].domains.map { $0.uris.map(\.path) })
        #expect(copy.description == nil)
        #expect(copy.pinned == false && copy.isDefault == false)
    }
}

@MainActor @Suite struct ProjectJSONTests {
    @Test func upgradesV1File() throws {
        let v1 = """
        { "version": 1, "projects": [ { "name": "Shop", "baseDomain": "example.com", "envs": [
          { "name": "dev", "domains": ["api.example.com", "localhost:3000"], "primary": "localhost:3000",
            "uris": ["/", "/login"], "accounts": ["admin"] } ] } ] }
        """
        let (projects, outdated) = try #require(ProjectJSON.decode(Data(v1.utf8)))
        #expect(outdated)
        let p = projects[0]
        let dev = p.envs[0]
        // 대표(primary)가 첫 번째, 대표 도메인 미사용 + 전체 host, ssl 은 추측 규칙
        #expect(dev.domains.map { p.host($0) } == ["localhost:3000", "api.example.com"])
        #expect(dev.domains.allSatisfy { !$0.useBase })
        #expect(dev.domains.map(\.ssl) == [false, true])
        // URI·계정은 대표 도메인으로
        #expect(dev.domains[0].uris.map(\.path) == ["/", "/login"])
        #expect(dev.domains[0].accounts == ["admin"])
        #expect(dev.domains[1].uris.isEmpty)
        #expect(p.url(dev, path: "/login")?.absoluteString == "http://localhost:3000/login")
    }

    @Test func paramsEncodeLikeProjectPage() {
        let u = EnvURI(path: "/go", params: [URIParam(key: "redirect", value: "https://a.com/x?y=1&z=한 글"),
                                             URIParam(key: "list", value: "a,b;c@d:e/f+g")])
        #expect(u.fullPath == "/go?redirect=https%3A%2F%2Fa.com%2Fx%3Fy%3D1%26z%3D%ED%95%9C%20%EA%B8%80&list=a%2Cb%3Bc%40d%3Ae%2Ff%2Bg")
    }

    @Test func pathVariables() {
        let u = EnvURI(path: "/users/{id}/orders/{no}", params: [URIParam(key: "id", value: "a/b 1"), URIParam(key: "page", value: "2"),
                                                                  URIParam(key: "no", value: "")])
        // 같은 이름은 path 에, 나머지는 쿼리에. 값이 비면 {no} 그대로.
        #expect(u.fullPath == "/users/a%2Fb%201/orders/{no}?page=2")
        #expect(EnvURI(path: "/users/{id}", params: [URIParam(key: "id", value: "7")]).fullPath == "/users/7")
    }

    @Test func fileURISkipsDomain() {
        let env = ProjectEnv(name: "dev", domains: [EnvDomain(useBase: false, sub: "localhost:3000")])
        let p = Project(name: "P", baseDomain: "", envs: [env])
        let file = EnvURI(path: "file:///Users/me/a%20b/index.html", params: [URIParam(key: "q", value: "1")])
        #expect(file.isFile)
        #expect(p.url(env, path: file.fullPath)?.absoluteString == "file:///Users/me/a%20b/index.html?q=1")
        // 도메인이 없어도 열린다
        let empty = ProjectEnv(name: "x", domains: [])
        #expect(p.url(empty, path: file.path)?.isFileURL == true)
        #expect(p.url(env, path: "/login")?.absoluteString == "https://localhost:3000/login")
    }

    @Test func hostUsesBaseDomain() {
        let p = Project(name: "P", baseDomain: "test.com", envs: [ProjectEnv(name: "dev", domains: [
            EnvDomain(sub: "api.dev."), EnvDomain(sub: ""), EnvDomain(sub: "dev-"), EnvDomain(ssl: false, useBase: false, sub: "localhost:8080"),
        ])])
        #expect(p.envs[0].domains.map { p.origin($0) } == ["https://api.dev.test.com", "https://test.com", "https://dev-test.com", "http://localhost:8080"])
        let uri = EnvURI(path: "/users", params: [URIParam(key: "q", value: "a b&c")])
        #expect(uri.fullPath == "/users?q=a%20b%26c")
    }

    @Test func upgradesV2PrefixWithDot() throws {
        let v2 = """
        { "version": 2, "projects": [ { "name": "Shop", "baseDomain": "test.com", "envs": [
          { "name": "dev", "domains": [ { "useBase": true, "sub": "api.dev" }, { "useBase": true, "sub": "" },
                                        { "useBase": false, "sub": "localhost:3000", "ssl": false } ] } ] } ] }
        """
        let (projects, outdated) = try #require(ProjectJSON.decode(Data(v2.utf8)))
        #expect(outdated)
        let p = projects[0]
        #expect(p.envs[0].domains.map { p.host($0) } == ["api.dev.test.com", "test.com", "localhost:3000"])
    }

    @Test func sqliteRoundTrip() throws {
        let db = try ProjectDB.open(path: nil)
        var projects = SampleData.projects
        projects[1].closed = true
        projects[1].envs[0].domains[0].uris[0].showInSidebar = false
        try ProjectDB.save(projects, to: db)
        #expect(try ProjectDB.load(db) == projects)
        // 다시 저장해도 (전체 다시 쓰기) 그대로
        projects.remove(at: 2)
        try ProjectDB.save(projects, to: db)
        #expect(try ProjectDB.load(db) == projects)
    }
}
