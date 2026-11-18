import Foundation

/// 프로젝트 저장 (SQLite). 위치: ~/Library/Application Support/Devlink/devlink.sqlite
/// 프로젝트 → 환경 → 도메인 → URI → parameter, 도메인 → 계정. 순서는 ord, 부모를 지우면 자식도 지워진다.
/// 저장은 전체를 한 트랜잭션으로 다시 쓴다 (데이터가 작고, 중간에 깨지지 않는다).
/// JSON(ProjectJSON) 은 내보내기·가져오기 형식으로만 쓴다.
enum ProjectDB {
    /// 2: 예전 표준 환경 이름(local·dev·stg·prd)을 대문자로 (이름은 입력한 그대로 보이게 바뀜)
    /// 3: 계정 이름 칸
    /// 5: 파라미터 사용 여부(enabled)
    /// 6: 계정 사용 여부(enabled)
    static let schemaVersion = 6

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Devlink/devlink.sqlite")
    }

    /// 앱이 쓰는 DB (파일). 테스트는 open(path: nil) 로 메모리 DB.
    static func openFile() throws -> Database {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try open(path: fileURL.path(percentEncoded: false))   // path() 는 공백을 %20 으로 바꾼다
    }

    static func open(path: String?) throws -> Database {
        let db = try Database(path: path)
        try migrate(db)
        return db
    }

    private static func migrate(_ db: Database) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        var version = 0
        try db.query("SELECT value FROM meta WHERE key = 'schema'") { version = Int($0.text(0)) ?? 0 }
        guard version < schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.exec("""
                CREATE TABLE projects (
                  id TEXT PRIMARY KEY, ord INTEGER NOT NULL, name TEXT NOT NULL, base_domain TEXT NOT NULL,
                  description TEXT, persist INTEGER NOT NULL, visit_check INTEGER NOT NULL,
                  pinned INTEGER NOT NULL, is_default INTEGER NOT NULL, closed INTEGER NOT NULL);
                CREATE TABLE envs (
                  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                  ord INTEGER NOT NULL, name TEXT NOT NULL, palette TEXT NOT NULL);
                CREATE TABLE domains (
                  id TEXT PRIMARY KEY, env_id TEXT NOT NULL REFERENCES envs(id) ON DELETE CASCADE,
                  ord INTEGER NOT NULL, alias TEXT NOT NULL, ssl INTEGER NOT NULL, use_base INTEGER NOT NULL,
                  sub TEXT NOT NULL, show_in_sidebar INTEGER NOT NULL);
                CREATE TABLE uris (
                  id TEXT PRIMARY KEY, domain_id TEXT NOT NULL REFERENCES domains(id) ON DELETE CASCADE,
                  ord INTEGER NOT NULL, alias TEXT NOT NULL, path TEXT NOT NULL, show_in_sidebar INTEGER NOT NULL);
                CREATE TABLE params (
                  uri_id TEXT NOT NULL REFERENCES uris(id) ON DELETE CASCADE,
                  ord INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, desc TEXT NOT NULL);
                CREATE TABLE accounts (
                  domain_id TEXT NOT NULL REFERENCES domains(id) ON DELETE CASCADE,
                  ord INTEGER NOT NULL, login_id TEXT NOT NULL);
                """)
            }
            if version < 2 {
                try db.exec("UPDATE envs SET name = upper(name) WHERE name IN ('local', 'dev', 'stg', 'prd')")
            }
            if version < 3 {
                try db.exec("ALTER TABLE accounts ADD COLUMN name TEXT NOT NULL DEFAULT ''")
            }
            if version < 4 {
                try db.exec("ALTER TABLE projects ADD COLUMN color TEXT")
            }
            if version < 5 {
                try db.exec("ALTER TABLE params ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1")
            }
            if version < 6 {
                try db.exec("ALTER TABLE accounts ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1")
            }
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema', ?)", [.text("\(schemaVersion)")])
        }
    }

    // MARK: 읽기

    static func load(_ db: Database) throws -> [Project] {
        var params: [UUID: [URIParam]] = [:]
        try db.query("SELECT uri_id, key, value, desc, enabled FROM params ORDER BY uri_id, ord") { r in
            params[r.uuid(0), default: []].append(URIParam(key: r.text(1), value: r.text(2), desc: r.text(3), enabled: r.bool(4)))
        }
        var uris: [UUID: [EnvURI]] = [:]
        try db.query("SELECT id, domain_id, alias, path, show_in_sidebar FROM uris ORDER BY domain_id, ord") { r in
            let id = r.uuid(0)
            uris[r.uuid(1), default: []].append(EnvURI(id: id, alias: r.text(2), path: r.text(3),
                                                       params: params[id] ?? [], showInSidebar: r.bool(4)))
        }
        var accounts: [UUID: [Account]] = [:]
        try db.query("SELECT domain_id, login_id, name, enabled FROM accounts ORDER BY domain_id, ord") { r in
            accounts[r.uuid(0), default: []].append(Account(login: r.text(1), name: r.text(2), enabled: r.bool(3)))
        }
        var domains: [UUID: [EnvDomain]] = [:]
        try db.query("SELECT id, env_id, alias, ssl, use_base, sub, show_in_sidebar FROM domains ORDER BY env_id, ord") { r in
            let id = r.uuid(0)
            domains[r.uuid(1), default: []].append(EnvDomain(
                id: id, alias: r.text(2), ssl: r.bool(3), useBase: r.bool(4), sub: r.text(5), showInSidebar: r.bool(6),
                uris: uris[id] ?? [], accounts: accounts[id] ?? []))
        }
        var envs: [UUID: [ProjectEnv]] = [:]
        try db.query("SELECT id, project_id, name, palette FROM envs ORDER BY project_id, ord") { r in
            let id = r.uuid(0)
            envs[r.uuid(1), default: []].append(ProjectEnv(
                id: id, name: r.text(2), palette: EnvPalette(rawValue: r.text(3)), domains: domains[id] ?? []))
        }
        var projects: [Project] = []
        try db.query("""
            SELECT id, name, base_domain, description, persist, visit_check, pinned, is_default, closed, color
            FROM projects ORDER BY ord
            """) { r in
            let id = r.uuid(0)
            projects.append(Project(id: id, name: r.text(1), baseDomain: r.text(2), envs: envs[id] ?? [],
                                    description: r.optionalText(3), visitCheck: r.bool(5),   // persist(4) 는 쓰지 않는 예전 칸
                                    pinned: r.bool(6), isDefault: r.bool(7), closed: r.bool(8),
                                    color: r.optionalText(9)))
        }
        return projects
    }

    // MARK: 저장 (전체를 다시 쓴다)

    static func save(_ projects: [Project], to db: Database) throws {
        try db.transaction {
            try db.run("DELETE FROM projects")   // 자식은 cascade 로 함께
            for (po, p) in projects.enumerated() {
                try db.run("""
                    INSERT INTO projects (id, ord, name, base_domain, description, persist, visit_check, pinned, is_default, closed, color)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(p.id.uuidString), .int(po), .text(p.name), .text(p.baseDomain), .optional(p.description),
                          .bool(false), .bool(p.visitCheck), .bool(p.pinned), .bool(p.isDefault), .bool(p.closed), .optional(p.color)])
                for (eo, e) in p.envs.enumerated() {
                    try db.run("INSERT INTO envs (id, project_id, ord, name, palette) VALUES (?, ?, ?, ?, ?)",
                               [.text(e.id.uuidString), .text(p.id.uuidString), .int(eo), .text(e.name), .text(e.palette.rawValue)])
                    for (dord, d) in e.domains.enumerated() {
                        try db.run("""
                            INSERT INTO domains (id, env_id, ord, alias, ssl, use_base, sub, show_in_sidebar)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, [.text(d.id.uuidString), .text(e.id.uuidString), .int(dord), .text(d.alias),
                                  .bool(d.ssl), .bool(d.useBase), .text(d.sub), .bool(d.showInSidebar)])
                        for (uo, u) in d.uris.enumerated() {
                            try db.run("INSERT INTO uris (id, domain_id, ord, alias, path, show_in_sidebar) VALUES (?, ?, ?, ?, ?, ?)",
                                       [.text(u.id.uuidString), .text(d.id.uuidString), .int(uo), .text(u.alias), .text(u.path),
                                        .bool(u.showInSidebar)])
                            for (ko, k) in u.params.enumerated() {
                                try db.run("INSERT INTO params (uri_id, ord, key, value, desc, enabled) VALUES (?, ?, ?, ?, ?, ?)",
                                           [.text(u.id.uuidString), .int(ko), .text(k.key), .text(k.value), .text(k.desc), .bool(k.enabled)])
                            }
                        }
                        for (ao, a) in d.accounts.enumerated() {
                            try db.run("INSERT INTO accounts (domain_id, ord, login_id, name, enabled) VALUES (?, ?, ?, ?, ?)",
                                       [.text(d.id.uuidString), .int(ao), .text(a.login), .text(a.name), .bool(a.enabled)])
                        }
                    }
                }
            }
        }
    }
}
