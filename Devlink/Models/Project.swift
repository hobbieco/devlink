import SwiftUI

// MARK: - Project / Environment (저장: ProjectDB → devlink.sqlite, 내보내기·가져오기: ProjectJSON)

/// URI 파라미터 (설정에서 따로 등록, 열기·복사할 때 인코딩해서 붙인다)
struct URIParam: Hashable {
    var key: String
    var value: String
    /// 값 설명 (코드 값의 뜻 등). 주소에는 들어가지 않는다.
    var desc = ""
    /// 주소에 붙일지. 끄면 목록에는 남고 열기·복사에서 빠진다.
    var enabled = true
}

/// 도메인(서비스)별 URI. method·body 는 API 모드에서 추가.
struct EnvURI: Identifiable, Hashable {
    var id = UUID()
    var alias = ""
    var path: String
    var params: [URIParam] = []
    /// 사이드바에 보일지 (도메인이 사이드바에 보일 때만 의미가 있다)
    var showInSidebar = true

    /// 파일 URI (path 가 file:// 로 시작하는 전체 주소). 도메인을 붙이지 않는다.
    var isFile: Bool { Self.isFile(path) }
    static func isFile(_ path: String) -> Bool { path.hasPrefix("file://") }

    /// path + 인코딩한 parameter (path 에 이미 ? 가 있으면 & 로 잇는다).
    /// path variable: key 가 path 의 {key} 와 같은 parameter 는 쿼리 대신 그 자리에 넣는다 (값이 비면 {key} 그대로).
    var fullPath: String {
        // 프로젝트 화면(JS encodeURIComponent)과 같은 규칙: 영숫자와 -_.!~*'() 만 그대로
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var resolved = path
        var query: [String] = []
        for p in params where !p.key.isEmpty {
            let token = "{\(p.key)}"
            if path.contains(token) {
                if !p.value.isEmpty { resolved = resolved.replacingOccurrences(of: token, with: enc(p.value)) }
            } else {
                query.append("\(enc(p.key))=\(enc(p.value))")
            }
        }
        if query.isEmpty { return resolved }
        return resolved + (path.contains("?") ? "&" : "?") + query.joined(separator: "&")
    }
}

/// 로그인 계정: 아이디(login) + 보기 쉬운 이름(name, 선택). 문자열 리터럴은 아이디만 있는 계정.
struct Account: Hashable, ExpressibleByStringLiteral {
    var login: String
    var name = ""
    /// 끄면 로그인 칸 자동 채우기 목록에서 빠진다 (설정에는 남는다)
    var enabled = true

    init(login: String, name: String = "", enabled: Bool = true) { self.login = login; self.name = name; self.enabled = enabled }
    init(stringLiteral value: String) { login = value }
}

/// 환경에 등록한 도메인 하나 = 서비스 하나. URI·계정은 도메인마다 따로.
struct EnvDomain: Identifiable, Hashable {
    var id = UUID()
    /// 표시 이름 (프로젝트 화면 표 제목). 비면 도메인을 보여준다.
    var alias = ""
    var ssl = true
    /// 대표 도메인 사용: host = 앞부분(sub) + 대표 도메인, 그대로 이어 붙임 ("api." · "dev-" 처럼 구분자도 직접).
    /// 끄면 sub 에 전체 host(포트 포함).
    var useBase = true
    var sub = ""
    var showInSidebar = true
    var uris: [EnvURI] = []
    var accounts: [Account] = []
}

struct ProjectEnv: Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 환경 색 (설정에서 자유롭게 고름)
    var palette: EnvPalette
    var color: Color { palette.color }
    /// 로컬은 포트별·nginx 도메인, MSA 는 서비스별 도메인 등 여러 개. 첫 번째가 환경의 홈.
    var domains: [EnvDomain]

    /// 환경·도메인·URI 의 id 를 새로 만든 사본
    var withNewIDs: ProjectEnv {
        var e = self
        e.id = UUID()
        e.domains = domains.map { d in
            var c = d
            c.id = UUID()
            c.uris = d.uris.map { var u = $0; u.id = UUID(); return u }
            return c
        }
        return e
    }

    init(id: UUID = UUID(), name: String, palette: EnvPalette? = nil, domains: [EnvDomain] = []) {
        self.id = id
        self.name = name
        self.palette = palette ?? EnvPalette.legacy(forEnvName: name) ?? .slate
        self.domains = domains
    }
}

struct Project: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseDomain: String
    var envs: [ProjectEnv]
    /// 카드 설명 (2줄까지 표시)
    var description: String?
    /// 다른 환경 / 외부 방문 검사
    var visitCheck = true
    /// 고정 영역 (목록 맨 앞, 드래그로만 바뀜)
    var pinned = false
    /// 첫 실행 때 만드는 기본 프로젝트: 고정 영역 첫 칸, 이동·고정 변경·삭제 불가
    var isDefault = false
    /// 끝난 프로젝트: 새 탭 화면 closed 영역 (사이드바에는 안 보임). 드래그로만 바뀜.
    var closed = false
    /// 프로젝트 색 "#RRGGBB" (탭 아래 띠). 없으면 투명 = 띠 없음.
    var color: String?

    var colorValue: Color? {
        guard let color, let hex = UInt32(color.dropFirst(), radix: 16) else { return nil }
        return Color(hex: hex)
    }

    // MARK: 주소 (대표 도메인 + 환경 도메인)

    func host(_ d: EnvDomain) -> String {
        let sub = d.sub.trimmingCharacters(in: .whitespaces)
        guard d.useBase else { return sub }
        return baseDomain.isEmpty ? "" : sub + baseDomain
    }

    /// "https://host" (host 가 비면 nil)
    func origin(_ d: EnvDomain) -> String? {
        let h = host(d)
        return h.isEmpty ? nil : "\(d.ssl ? "https" : "http")://\(h)"
    }

    /// 환경의 홈 도메인: host 가 있는 첫 번째 도메인
    /// 사용(Active) 중인 도메인만 홈 도메인이 된다
    func homeDomain(_ env: ProjectEnv) -> EnvDomain? { env.domains.first { $0.showInSidebar && origin($0) != nil } }

    func isReady(_ env: ProjectEnv) -> Bool { homeDomain(env) != nil }

    /// domain 이 없으면 환경의 홈 도메인
    func url(_ env: ProjectEnv, domain: EnvDomain? = nil, path: String) -> URL? {
        if EnvURI.isFile(path) { return URL(string: path) }   // 파일 URI 는 도메인과 무관
        guard let d = domain ?? homeDomain(env), let o = origin(d) else { return nil }
        return URL(string: o + path)
    }

    /// 방문 검사용 host[:port] 목록
    func hosts(_ env: ProjectEnv) -> [String] {
        env.domains.map { host($0).lowercased() }.filter { !$0.isEmpty }
    }

    /// 기본 프로젝트 (일반 브라우징용)
    static func makeDefault() -> Project {
        var p = makeNew(name: "Default", baseDomain: "")
        p.isDefault = true
        return p
    }

    /// 복제: 선택한 항목만. 설명·썸네일·비밀번호는 복사하지 않는다.
    /// 도메인을 빼도 URI·계정을 복사하면 도메인 자리(이름)는 남긴다.
    /// 환경은 항상 모두 복제한다 (도메인·URI·계정은 선택).
    func duplicated(name: String, domains: Bool, uris: Bool, accounts: Bool) -> Project {
        let envCopies: [ProjectEnv] = envs.map { env in
            let doms: [EnvDomain] = (domains || uris || accounts) ? env.domains.map { d in
                var c = d
                c.id = UUID()
                if !domains { c.sub = ""; c.useBase = true }
                c.uris = uris ? d.uris.map { var u = $0; u.id = UUID(); return u } : []
                c.accounts = accounts ? d.accounts : []
                return c
            } : []
            return ProjectEnv(name: env.name, palette: env.palette, domains: doms)
        }
        return Project(name: name, baseDomain: domains ? baseDomain : "", envs: envCopies,
                       visitCheck: visitCheck, color: color)
    }

    /// 가져오기용 사본: 프로젝트·환경·도메인·URI 의 id 를 모두 새로 만든다.
    func withNewIDs() -> Project {
        var p = self
        p.id = UUID()
        p.envs = envs.map(\.withNewIDs)
        return p
    }

    /// 새 프로젝트: LOCAL 환경 하나 (다른 환경은 설정에서 추가). 첫 색.
    static func makeNew(name: String, baseDomain: String) -> Project {
        Project(name: name, baseDomain: baseDomain, envs: [ProjectEnv(name: "LOCAL", palette: EnvPalette.defaultColor(forIndex: 0))])
    }

    /// 환경 추가 시 기본 색: 색 순서대로 (지금 환경 개수 번째)
    func nextPalette() -> EnvPalette { EnvPalette.defaultColor(forIndex: envs.count) }
}

enum SampleData {
    private static func uris(_ paths: [String]) -> [EnvURI] { paths.map { EnvURI(path: $0) } }

    static let projects: [Project] = [
        Project.makeDefault(),
        Project(name: "Sample Shop", baseDomain: "example.com", envs: [
            ProjectEnv(name: "LOCAL", domains: [
                EnvDomain(alias: "Web", ssl: false, useBase: false, sub: "localhost:3000",
                          uris: [EnvURI(alias: "Home", path: "/"), EnvURI(alias: "Login", path: "/login"),
                                 EnvURI(alias: "Products", path: "/products", params: [URIParam(key: "page", value: "1", desc: "Page number, from 1")]),
                                 EnvURI(path: "/cart")],
                          accounts: ["admin", "user01"]),
                EnvDomain(alias: "API", ssl: false, useBase: false, sub: "localhost:8080",
                          uris: uris(["/health", "/api/products"])),
                EnvDomain(ssl: false, useBase: false, sub: "shop.local", showInSidebar: false),
            ]),
            ProjectEnv(name: "DEV", domains: [
                EnvDomain(alias: "Web", sub: "dev.", uris: uris(["/", "/login", "/products", "/cart"]),
                          accounts: ["admin", "user01"]),
                EnvDomain(alias: "API", sub: "dev-api.", uris: uris(["/health"])),
            ]),
            ProjectEnv(name: "STG", domains: [
                EnvDomain(alias: "Web", sub: "stg.", uris: uris(["/", "/login", "/products"]), accounts: ["admin"]),
            ]),
            ProjectEnv(name: "PRD", domains: [
                EnvDomain(alias: "Web", sub: "www.", uris: uris(["/", "/login"]), accounts: ["qa-viewer"]),
                EnvDomain(alias: "API", sub: "api."),
                EnvDomain(alias: "SSO", useBase: false, sub: "sso.example.net", showInSidebar: false),
            ]),
            ProjectEnv(name: "gsc", palette: .blue, domains: [
                EnvDomain(sub: "gsc.", uris: uris(["/", "/login"]), accounts: ["auditor"]),
            ]),
        ], description: "Sample project for comparing the shop front and admin across environments. Long descriptions show only two lines."),
        Project(name: "Admin Console", baseDomain: "example.org", envs: [
            ProjectEnv(name: "DEV", domains: [
                EnvDomain(sub: "dev-admin.", uris: uris(["/", "/login", "/users"]), accounts: ["root"]),
            ]),
            ProjectEnv(name: "PRD", domains: [
                EnvDomain(sub: "admin.", uris: uris(["/", "/login"]), accounts: ["root"]),
            ]),
        ]),
    ]
}

// MARK: - 설정 화면에서 받은 값 (JS → Swift). 새 항목은 id 가 없으면 새로 만든다. 마지막 검증은 여기서.

extension Project {
    /// 원본(base)에 설정 화면 값을 덮어쓴다.
    /// passwords: 계정 행의 비밀번호를 PasswordStore.itemKey → 값으로 돌려준다 (빈 값 = 지움).
    init?(edited d: [String: Any], base: Project, passwords: inout [String: String]) {
        func str(_ o: [String: Any], _ k: String) -> String {
            (o[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func uuid(_ o: [String: Any]) -> UUID { (o["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID() }
        func list(_ o: [String: Any], _ k: String) -> [[String: Any]] { o[k] as? [[String: Any]] ?? [] }

        let name = str(d, "name")
        guard !name.isEmpty else { return nil }
        self = base
        self.name = name
        baseDomain = str(d, "baseDomain").lowercased()
        let desc = str(d, "description")
        description = desc.isEmpty ? nil : desc
        visitCheck = d["visitCheck"] as? Bool ?? base.visitCheck
        let c = str(d, "color")
        color = c.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? c.uppercased() : nil
        envs = list(d, "envs").compactMap { e in
            let envName = str(e, "name")
            guard !envName.isEmpty else { return nil }
            let id = uuid(e)
            let old = base.envs.first { $0.id == id }
            let domains = list(e, "domains").map { dm in
                let domainID = uuid(dm)
                // 계정: {id, pw}. 아이디가 빈 행은 버린다.
                var accounts: [Account] = []
                for a in list(dm, "accounts") {
                    let account = str(a, "id")
                    guard !account.isEmpty else { continue }
                    accounts.append(Account(login: account, name: str(a, "name"), enabled: a["enabled"] as? Bool ?? true))
                    passwords[PasswordStore.itemKey(domain: domainID, account: account)] = a["pw"] as? String ?? ""
                }
                return EnvDomain(id: domainID, alias: str(dm, "alias"), ssl: dm["ssl"] as? Bool ?? true,
                          useBase: dm["useBase"] as? Bool ?? true, sub: str(dm, "sub").lowercased(),
                          showInSidebar: dm["showInSidebar"] as? Bool ?? true,
                          uris: list(dm, "uris").compactMap { u in
                              let path = str(u, "path")
                              guard !path.isEmpty else { return nil }
                              return EnvURI(id: uuid(u), alias: str(u, "alias"),
                                            path: path.hasPrefix("/") || EnvURI.isFile(path) ? path : "/" + path,
                                            params: list(u, "params").compactMap { pr in
                                                let key = str(pr, "key")
                                                return key.isEmpty ? nil : URIParam(key: key, value: pr["value"] as? String ?? "",
                                                                                    desc: str(pr, "desc"), enabled: pr["enabled"] as? Bool ?? true)
                                            },
                                            showInSidebar: u["showInSidebar"] as? Bool ?? true)
                          },
                          accounts: accounts)
            }
            let palette = (e["palette"] as? String).flatMap(EnvPalette.init(rawValue:)) ?? old?.palette ?? base.nextPalette()
            return ProjectEnv(id: id, name: envName, palette: palette,
                              domains: domains)
        }
        guard !envs.isEmpty else { return nil }   // 환경은 최소 1개
    }
}
