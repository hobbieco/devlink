import Foundation
import Observation
import SwiftUI

/// 프로젝트 JSON: 내보내기·가져오기 형식 (저장은 ProjectDB = SQLite). 가져오기 화면은 아직 없다.
///
/// { "version": 2,
///   "projects": [ { "id": "…", "order": 0, "name": "My Service", "baseDomain": "example.com",
///                   "description": "…", "visitCheck": true,
///                   "envs": [ { "id": "…", "order": 0, "name": "dev",
///                               "domains": [ { "id": "…", "alias": "API", "ssl": true, "useBase": true, "sub": "api.dev",
///                                              "showInSidebar": true, "accounts": ["admin"],
///                                              "uris": [ { "id": "…", "alias": "회원", "path": "/users",
///                                                          "params": [ { "key": "page", "value": "1" } ] } ] } ] } ] } ] }
/// 예전 형식도 읽는다: 프로젝트 배열만 있는 파일, v1 (domains 가 문자열 배열, 환경에 uris·accounts).
/// v1 도메인은 "대표 도메인 미사용 + 전체 host" 로, URI·계정은 대표(primary) 도메인으로 옮긴다.
enum ProjectJSON {
    /// 3: 대표 도메인 사용 시 앞부분을 그대로 이어 붙임 (2 까지는 사이에 "." 을 자동으로 넣었다)
    /// 4: 환경 이름은 입력한 그대로 (3 까지는 local·dev·stg·prd 를 화면에서만 대문자로 보였다)
    static let version = 4

    /// outdated: 예전 형식 (가져오면서 지금 형식으로 바뀜)
    static func decode(_ data: Data) -> (projects: [Project], outdated: Bool)? {
        do {
            let dtos: [ProjectDTO]
            var outdated = true
            var fileVersion = 0
            if let file = try? JSONDecoder().decode(FileDTO.self, from: data) {
                dtos = file.projects
                fileVersion = file.version
                outdated = file.version < version
            } else {
                dtos = try JSONDecoder().decode([ProjectDTO].self, from: data)
            }
            var projects = dtos.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.project)
            if fileVersion == 2 { projects = projects.map(addDotAfterPrefix) }
            if fileVersion < 4 { projects = projects.map(uppercaseLegacyEnvNames) }
            return (projects, outdated)
        } catch {
            NSLog("Devlink: failed to read project JSON: \(error)")
            return nil
        }
    }

    /// v3 → v4: 화면에 대문자로 보이던 예전 표준 이름을 실제로 대문자로
    static func uppercaseLegacyEnvNames(_ p: Project) -> Project {
        var p = p
        for i in p.envs.indices where EnvPalette.legacyEnvNames.contains(p.envs[i].name) {
            p.envs[i].name = p.envs[i].name.uppercased()
        }
        return p
    }

    /// v2 → v3: 앞부분 뒤에 있던 자동 "." 을 데이터에 넣어 주소를 그대로 유지
    private static func addDotAfterPrefix(_ p: Project) -> Project {
        var p = p
        for e in p.envs.indices {
            for d in p.envs[e].domains.indices {
                let sub = p.envs[e].domains[d].sub
                if p.envs[e].domains[d].useBase && !sub.isEmpty && !sub.hasSuffix(".") && !sub.hasSuffix("-") {
                    p.envs[e].domains[d].sub = sub + "."
                }
            }
        }
        return p
    }

    /// 내보내기용 JSON
    static func encode(_ projects: [Project]) throws -> Data {
        let file = FileDTO(version: version,
                           projects: projects.enumerated().map { ProjectDTO($0.element, order: $0.offset) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    // MARK: DTO (테이블 모양: id + order)

    private struct FileDTO: Codable {
        var version: Int
        var projects: [ProjectDTO]
    }

    private struct ProjectDTO: Codable {
        var id: UUID?
        var order: Int?
        var name: String
        var baseDomain: String?
        var description: String?
        var visitCheck: Bool?
        var pinned: Bool?
        var isDefault: Bool?
        var closed: Bool?
        var color: String?
        var envs: [EnvDTO]

        init(_ p: Project, order: Int) {
            id = p.id; self.order = order; name = p.name; baseDomain = p.baseDomain
            description = p.description
            visitCheck = p.visitCheck
            pinned = p.pinned ? true : nil; isDefault = p.isDefault ? true : nil; closed = p.closed ? true : nil
            color = p.color
            envs = p.envs.enumerated().map { EnvDTO($0.element, order: $0.offset) }
        }

        var project: Project {
            Project(id: id ?? UUID(), name: name, baseDomain: baseDomain ?? "",
                    envs: envs.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.env),
                    description: description, visitCheck: visitCheck ?? true,
                    pinned: pinned ?? false, isDefault: isDefault ?? false, closed: closed ?? false, color: color)
        }
    }

    private struct EnvDTO: Codable {
        var id: UUID?
        var order: Int?
        var name: String
        var palette: String?
        var domains: [DomainDTO]

        init(_ e: ProjectEnv, order: Int) {
            id = e.id; self.order = order; name = e.name
            palette = e.palette.rawValue
            domains = e.domains.map(DomainDTO.init)
        }

        private enum CodingKeys: String, CodingKey { case id, order, name, palette, domains, primary, uris, accounts }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id)
            order = try c.decodeIfPresent(Int.self, forKey: .order)
            name = try c.decode(String.self, forKey: .name)
            palette = try c.decodeIfPresent(String.self, forKey: .palette)
            if let v2 = try? c.decode([DomainDTO].self, forKey: .domains) {
                domains = v2
                return
            }
            // v1: 문자열 도메인. 대표(primary)를 앞으로, URI·계정은 대표 도메인에.
            var hosts = (try? c.decode([String].self, forKey: .domains)) ?? []
            if let primary = try c.decodeIfPresent(String.self, forKey: .primary), let i = hosts.firstIndex(of: primary) {
                hosts.insert(hosts.remove(at: i), at: 0)
            }
            let uris = (try c.decodeIfPresent([String].self, forKey: .uris)) ?? []
            let accounts = (try c.decodeIfPresent([String].self, forKey: .accounts)) ?? []
            domains = hosts.enumerated().map { i, host in
                let local = host.hasPrefix("localhost") || host.hasSuffix(".local")
                return DomainDTO(EnvDomain(ssl: !local, useBase: false, sub: host,
                                           uris: i == 0 ? uris.map { EnvURI(path: $0) } : [],
                                           accounts: i == 0 ? accounts.map { Account(login: $0) } : []))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(order, forKey: .order)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(palette, forKey: .palette)
            try c.encode(domains, forKey: .domains)
        }

        var env: ProjectEnv {
            ProjectEnv(id: id ?? UUID(), name: name, palette: palette.flatMap(EnvPalette.init(rawValue:)),
                       domains: domains.map(\.domain))
        }
    }

    private struct DomainDTO: Codable {
        var id: UUID?
        var alias: String?
        var ssl: Bool?
        var useBase: Bool?
        var sub: String?
        var showInSidebar: Bool?
        var swaggerAuth: Bool?    // 켠 것만 기록
        var tokenPrefix: String?  // Bearer 가 아닐 때만 기록 (빈 값 = 접두사 없음)
        var tokenKey: String?
        var tokenPath: String?
        var uris: [URIDTO]?
        var accounts: [AccountDTO]?

        init(_ d: EnvDomain) {
            id = d.id; alias = d.alias; ssl = d.ssl; useBase = d.useBase; sub = d.sub
            showInSidebar = d.showInSidebar; uris = d.uris.map(URIDTO.init)
            swaggerAuth = d.swaggerAuth ? true : nil
            tokenPrefix = d.tokenPrefix == "Bearer" ? nil : d.tokenPrefix
            tokenKey = d.tokenKey.isEmpty ? nil : d.tokenKey
            tokenPath = d.tokenPath.isEmpty ? nil : d.tokenPath
            accounts = d.accounts.map(AccountDTO.init)
        }

        var domain: EnvDomain {
            EnvDomain(id: id ?? UUID(), alias: alias ?? "", ssl: ssl ?? true, useBase: useBase ?? true, sub: sub ?? "",
                      showInSidebar: showInSidebar ?? true, swaggerAuth: swaggerAuth ?? false, tokenPrefix: tokenPrefix ?? "Bearer",
                      tokenKey: tokenKey ?? "", tokenPath: tokenPath ?? "",
                      uris: (uris ?? []).map(\.uri), accounts: (accounts ?? []).map(\.account))
        }
    }

    /// 계정: 이름이 없으면 예전처럼 아이디 문자열 하나, 있으면 {login, name}. 둘 다 읽는다.
    private struct AccountDTO: Codable {
        var login: String
        var name: String
        var enabled: Bool?   // 꺼진 것만 기록
        var http: Bool?      // HTTP 인증용인 것만 기록

        init(_ a: Account) { login = a.login; name = a.name; enabled = a.enabled ? nil : false; http = a.http ? true : nil }
        var account: Account { Account(login: login, name: name, enabled: enabled ?? true, http: http ?? false) }

        private enum CodingKeys: String, CodingKey { case login, name, enabled, http }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) { login = text; name = ""; return }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            login = try c.decode(String.self, forKey: .login)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
            http = try c.decodeIfPresent(Bool.self, forKey: .http)
        }

        func encode(to encoder: Encoder) throws {
            if name.isEmpty && enabled == nil && http == nil {
                var c = encoder.singleValueContainer()
                try c.encode(login)
            } else {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(login, forKey: .login)
                if !name.isEmpty { try c.encode(name, forKey: .name) }
                try c.encodeIfPresent(enabled, forKey: .enabled)
                try c.encodeIfPresent(http, forKey: .http)
            }
        }
    }

    private struct URIDTO: Codable {
        var id: UUID?
        var alias: String?
        var path: String
        var params: [ParamDTO]?
        var showInSidebar: Bool?

        init(_ u: EnvURI) {
            id = u.id; alias = u.alias; path = u.path
            showInSidebar = u.showInSidebar ? nil : false
            params = u.params.map { ParamDTO(key: $0.key, value: $0.value, desc: $0.desc.isEmpty ? nil : $0.desc, enabled: $0.enabled ? nil : false) }
        }

        var uri: EnvURI {
            EnvURI(id: id ?? UUID(), alias: alias ?? "", path: path,
                   params: (params ?? []).map { URIParam(key: $0.key, value: $0.value, desc: $0.desc ?? "", enabled: $0.enabled ?? true) },
                   showInSidebar: showInSidebar ?? true)
        }
    }

    private struct ParamDTO: Codable {
        var key: String
        var value: String
        var desc: String?
        var enabled: Bool?   // 꺼진 것만 기록
    }
}

/// 앱 전체에서 하나인 프로젝트 목록. 모든 창·탭·사이드바가 이것을 본다 (여러 창 동시 저장 충돌 방지).
@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    var projects: [Project]
    /// 저장 DB. 테스트·데모에서는 nil (파일을 읽거나 쓰지 않고 샘플 데이터).
    @ObservationIgnored private let db: Database?

    private init() {
        let env = ProcessInfo.processInfo.environment
        let persists = env["XCTestConfigurationFilePath"] == nil && env["DEVLINK_DEMO"] == nil
        var opened: Database?
        if persists {
            do { opened = try ProjectDB.openFile() } catch { NSLog("Devlink: failed to open DB: \(error)") }
        }
        db = opened
        if let db = opened {
            // 처음이면 비어 있다 → Default 만 (예전 projects.json 은 가져오기로 넣는다)
            projects = (try? ProjectDB.load(db)) ?? []
        } else {
            // 테스트·데모는 샘플. 실제 앱에서 DB 를 못 열면 샘플을 보여주지 않는다 (Default 만, 저장 안 됨).
            projects = persists ? [] : SampleData.projects
        }
        // Default 가 없거나 순서가 어긋나면 고쳐서 저장. 초기화 중이라 알림(save)은 보내지 않는다
        // (알림을 받은 화면이 아직 만들어지는 중인 shared 에 접근하면 멈춘다).
        if normalize(), let db = opened { try? ProjectDB.save(projects, to: db) }
    }

    // 순서 규칙: Default → 고정 → 일반 → closed

    var defaultProject: Project? { projects.first { $0.isDefault } }
    var pinnedProjects: [Project] { projects.filter { $0.pinned && !$0.isDefault && !$0.closed } }
    var otherProjects: [Project] { projects.filter { !$0.pinned && !$0.isDefault && !$0.closed } }
    var closedProjects: [Project] { projects.filter { $0.closed && !$0.isDefault } }

    /// 순서 규칙을 맞추고 Default 가 하나 있게 한다. 바뀌었으면 true.
    @discardableResult
    func normalize() -> Bool {
        var defaults = projects.filter(\.isDefault)
        if defaults.isEmpty { defaults = [Project.makeDefault()] }
        var first = defaults[0]
        first.pinned = true
        first.closed = false
        let result = [first] + pinnedProjects + otherProjects + closedProjects
        guard result != projects else { return false }
        projects = result
        return true
    }

    /// 드래그 결과 반영: 영역별 순서 (영역을 넘으면 고정·일반·closed 상태가 바뀐다). 즉시 저장.
    /// closed 가 nil 이면 closed 영역은 그대로 둔다.
    func reorder(pinned: [UUID], others: [UUID], closed: [UUID]? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let closedIDs = closed ?? closedProjects.map(\.id)
        func take(_ ids: [UUID], pinned: Bool, closed: Bool) -> [Project] {
            ids.compactMap { byID[$0] }.filter { !$0.isDefault }.map {
                var p = $0; p.pinned = pinned; p.closed = closed; return p
            }
        }
        var result: [Project] = defaultProject.map { [$0] } ?? []
        result += take(pinned, pinned: true, closed: false)
        result += take(others, pinned: false, closed: false)
        result += take(closedIDs, pinned: false, closed: true)
        let listed = Set(pinned + others + closedIDs)
        result += projects.filter { !listed.contains($0.id) && !$0.isDefault }   // 화면에 없던 것(검색 등)은 유지
        guard result != projects else { return }
        projects = result
        save()
    }

    /// 설정 화면 저장: 편집한 값으로 바꾼다 (순서·고정·closed·Default 여부는 그대로). 즉시 저장.
    func update(_ edited: Project) {
        guard let i = projects.firstIndex(where: { $0.id == edited.id }) else { return }
        var p = edited
        p.pinned = projects[i].pinned
        p.closed = projects[i].closed
        p.isDefault = projects[i].isDefault
        projects[i] = p
        save()
    }

    /// 프로젝트 삭제 (Default 는 지울 수 없다). 즉시 저장.
    func delete(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }), !p.isDefault else { return }
        projects.removeAll { $0.id == id }
        save()
    }

    /// 새 프로젝트: 일반 영역 맨 앞. 이름이 비면 New Project, 같은 이름이 있으면 번호.
    func create(name rawName: String, from source: Project? = nil,
                domains: Bool = true, uris: Bool = true, accounts: Bool = false) -> Project {
        let name = uniqueName(rawName.trimmingCharacters(in: .whitespacesAndNewlines))
        let project = source?.duplicated(name: name, domains: domains, uris: uris, accounts: accounts)
            ?? Project.makeNew(name: name, baseDomain: "")
        projects = (defaultProject.map { [$0] } ?? []) + pinnedProjects + [project] + otherProjects + closedProjects
        save()
        return project
    }

    /// 가져오기 대상 (closed·Default 제외)
    var importTargets: [Project] { projects.filter { !$0.isDefault && !$0.closed } }

    /// 가져오기: target 이 nil 이면 새 프로젝트(파일의 pinned·closed 상태에 따라 고정·일반·닫힘 영역 각각 맨 뒤, 이름이 겹치면 번호),
    /// 아니면 그 프로젝트의 환경 맨 뒤에 환경을 그대로 붙인다 (중복 검사 없음). id 는 모두 새로 만든다. 즉시 저장.
    /// 반환: 가져온 프로젝트 이름 (대상이 없어졌으면 nil).
    @discardableResult
    func importProject(_ incoming: Project, into target: UUID?) -> String? {
        let copy = incoming.withNewIDs()
        if let target {
            guard let i = projects.firstIndex(where: { $0.id == target && !$0.isDefault && !$0.closed }) else { return nil }
            projects[i].envs += copy.envs
            save()
            return projects[i].name
        }
        var p = copy
        p.name = uniqueName(p.name)
        p.isDefault = false   // pinned·closed 는 파일 그대로 (둘 다 켜져 있으면 closed 가 우선)
        if p.closed { p.pinned = false }
        let isPinned = p.pinned, isClosed = p.closed
        projects = (defaultProject.map { [$0] } ?? []) + pinnedProjects + (isPinned ? [p] : [])
            + otherProjects + (!isPinned && !isClosed ? [p] : [])
            + closedProjects + (isClosed ? [p] : [])
        save()
        return p.name
    }

    func uniqueName(_ base: String) -> String {
        let base = base.isEmpty ? "New Project" : base
        let names = Set(projects.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    func save() {
        NotificationCenter.default.post(name: .devlinkProjectsChanged, object: nil)
        guard let db else { return }
        // 없어진 도메인·계정의 비밀번호는 함께 지운다
        PasswordStore.shared.prune(keeping: Set(projects.flatMap { $0.envs.flatMap(\.domains) }.flatMap { d in
            d.accounts.map { PasswordStore.itemKey(domain: d.id, account: $0.login) }
        }))
        do { try ProjectDB.save(projects, to: db) } catch { NSLog("Devlink: failed to save DB: \(error)") }
    }
}

extension Notification.Name {
    static let devlinkProjectsChanged = Notification.Name("devlinkProjectsChanged")
}
