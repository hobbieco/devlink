import AppKit
import SwiftUI

/// ③ 사이드바: Default·고정 → (구분선) → 일반. closed 는 숨김. 드래그 없음.
/// 프로젝트 → 환경 → URI (사이드바 표시인 도메인·URI 만, 이름은 "도메인 이름 · URI 이름").
/// 클릭 = 선택(하단 정보), 더블클릭 = 활성 탭 바로 뒤에 열기, 우클릭(URI 줄만) = 열기·복사 메뉴.
struct SidebarView: View {
    let state: WindowState
    @State private var expanded: Set<UUID> = []
    @State private var selection: SidebarItem?
    @AppStorage("sidebarInfoCollapsed") private var infoCollapsed = false

    private var library: ProjectLibrary { ProjectLibrary.shared }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    if let def = library.defaultProject { projectRow(def) }
                    ForEach(library.pinnedProjects) { projectRow($0) }
                    ForEach(library.otherProjects) { p in
                        projectRow(p, separatorAbove: p.id == library.otherProjects.first?.id)
                    }
                } header: {
                    Text("Projects")
                }
            }
            .listStyle(.sidebar)
            // 순서만 바뀌면 macOS 목록이 줄을 다시 배치하지 않아서, 순서(고정 포함)가 바뀌면 새로 그린다.
            // 펼침·선택 상태는 이 뷰의 @State 라 유지된다.
            .id(library.projects.map { "\($0.id)\($0.pinned)\($0.closed)" })
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                if let item = items.first, case .uri = item { uriMenu(item) }
            } primaryAction: { items in
                if let item = items.first { open(item) }
            }

            SidebarInfoPanel(item: selection, collapsed: $infoCollapsed)
        }
    }

    // MARK: Rows

    private func projectRow(_ project: Project, separatorAbove: Bool = false) -> some View {
        DisclosureGroup(isExpanded: binding(project.id)) {
            ForEach(project.envs) { env in
                DisclosureGroup(isExpanded: binding(env.id)) {
                    // 환경 아래에 URI 를 바로: 도메인 순서 → URI 순서, 사이드바 표시인 것만
                    ForEach(Self.sidebarURIs(env), id: \.key) { row in
                        uriLabel(domain: row.domain, uri: row.uri)
                            .font(UIMetrics.font)
                            .help(row.uri.fullPath)
                            .tag(SidebarItem.uri(project.id, env.id, row.domain.id, row.index))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(env.color).frame(width: 8, height: 8)
                        Text(env.name)
                    }
                    .font(UIMetrics.font)
                }
                .tag(SidebarItem.env(project.id, env.id))
            }
        } label: {
            Label(project.name, systemImage: project.isDefault ? "house" : (project.pinned ? "pin" : "folder"))
                .font(UIMetrics.font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, separatorAbove ? 12 : 0)   // 구분선 위아래 여백
                .overlay(alignment: .top) {
                    if separatorAbove {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                            .padding(.leading, -24)   // 펼침 화살표 아래까지
                            .offset(y: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        .tag(SidebarItem.project(project.id))
    }

    /// URI 줄 이름: "도메인 이름 · URI 이름". 도메인 이름이 없으면 앞부분 생략, URI 이름이 없으면 path.
    private func uriLabel(domain: EnvDomain, uri: EnvURI) -> some View {
        Label {
            HStack(spacing: 0) {
                if !domain.alias.isEmpty { Text("\(domain.alias) · ").foregroundStyle(.secondary) }
                Text(!uri.alias.isEmpty ? uri.alias : uri.isFile ? URL(string: uri.path)?.lastPathComponent ?? uri.path : uri.path)
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: "link")
        }
    }

    private struct URIRow {
        let domain: EnvDomain
        let index: Int   // 도메인 URI 목록 안의 원래 위치
        let uri: EnvURI
        var key: String { "\(domain.id)/\(index)" }
    }

    private static func sidebarURIs(_ env: ProjectEnv) -> [URIRow] {
        env.domains.filter(\.showInSidebar).flatMap { d in
            d.uris.enumerated().filter { $0.element.showInSidebar }.map { URIRow(domain: d, index: $0.offset, uri: $0.element) }
        }
    }

    // MARK: Actions

    /// 더블클릭: 활성 탭 바로 뒤에 연다.
    private func open(_ item: SidebarItem) {
        let r = item.resolve(in: library)
        switch item {
        case .project:
            if let p = r.project { state.openProjectPage(p) }
        case .env, .uri:
            if let p = r.project, let e = r.env {
                state.openInNewTab(project: p, env: e, domain: r.domain, path: r.uri?.fullPath ?? "/")
            }
        }
    }

    @ViewBuilder
    private func uriMenu(_ item: SidebarItem) -> some View {
        let r = item.resolve(in: library)
        if let p = r.project, let e = r.env, let d = r.domain, let path = r.uri?.fullPath {
            Button("Open in Tab") { state.openInNewTab(project: p, env: e, domain: d, path: path) }
            Button("Open in Group Tab") { state.openInGroupTab(project: p, env: e, domain: d, path: path) }
                .disabled(!state.canOpenInGroup)
            Button("Open in Split View") { state.openInRightPane(project: p, env: e, domain: d, path: path) }
            Button("Open in New Window") {}.disabled(true)   // 탭 드래그 2단계(새 창)와 함께
            Divider()
            Button("Copy URL") { copy(p.url(e, domain: d, path: path)?.absoluteString ?? path) }
            Button("Copy URI") { copy(path) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }
}

// MARK: - Selection

enum SidebarItem: Hashable {
    case project(UUID)
    case env(UUID, UUID)
    case uri(UUID, UUID, UUID, Int)

    struct Resolved {
        var project: Project?
        var env: ProjectEnv?
        var domain: EnvDomain?
        var uri: EnvURI?
    }

    func resolve(in library: ProjectLibrary) -> Resolved {
        func proj(_ id: UUID) -> Project? { library.projects.first { $0.id == id } }
        switch self {
        case .project(let pid):
            return Resolved(project: proj(pid))
        case .env(let pid, let eid):
            let p = proj(pid)
            return Resolved(project: p, env: p?.envs.first { $0.id == eid })
        case .uri(let pid, let eid, let did, let index):
            let p = proj(pid)
            let e = p?.envs.first { $0.id == eid }
            let d = e?.domains.first { $0.id == did }
            let u = d.flatMap { index < $0.uris.count ? $0.uris[index] : nil }
            return Resolved(project: p, env: e, domain: d, uri: u)
        }
    }
}

// MARK: - 하단 정보 (고정, 접기 가능)

struct SidebarInfoPanel: View {
    let item: SidebarItem?
    @Binding var collapsed: Bool

    var body: some View {
        let r = item?.resolve(in: ProjectLibrary.shared) ?? .init()
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Info").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { collapsed.toggle() }
            .help(collapsed ? String(localized: "Expand info") : String(localized: "Collapse info"))

            if !collapsed {
                VStack(alignment: .leading, spacing: 4) {
                    row("Project", r.project?.name)
                    row("Env", r.env?.name, dot: r.env?.color)
                    row("Domain", r.project.flatMap { p in (r.domain ?? r.env.flatMap(p.homeDomain)).flatMap(p.origin) })
                    row("Name", r.uri.flatMap { $0.alias.isEmpty ? nil : $0.alias })
                    row("URI", r.uri?.fullPath)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .font(UIMetrics.font)
    }

    private func row(_ label: String, _ value: String?, dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            if let dot, value != nil { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value ?? "")
        }
    }
}
