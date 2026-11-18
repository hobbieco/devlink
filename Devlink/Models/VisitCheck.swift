import Foundation

/// 탭의 현재 주소가 탭의 최초 환경 기준으로 어디를 방문 중인지.
enum VisitStatus: Equatable {
    case sameEnv
    case otherEnv(project: String, env: String)
    case external
    /// 프로젝트 옵션에서 방문 검사를 끔
    case unchecked
}

extension WindowState {
    /// 지금은 host[:port] 단순 비교. 공통 도메인, 대표 도메인 우선 등 세부 규칙은 등록 화면 구현 시 여기에 추가.
    func visitStatus(of tab: BrowserTab) -> VisitStatus {
        guard case .page(let pid, let eid, _) = tab.content,
              let (project, env) = env(pid, eid) else { return .unchecked }
        guard project.visitCheck else { return .unchecked }
        guard let key = tab.currentURL.flatMap(Self.hostKey) else { return .sameEnv }

        if project.hosts(env).contains(key) { return .sameEnv }
        for p in projects {
            for e in p.envs where e.id != env.id && p.hosts(e).contains(key) {
                return .otherEnv(project: p.name, env: e.name)
            }
        }
        return .external
    }

    static func hostKey(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
