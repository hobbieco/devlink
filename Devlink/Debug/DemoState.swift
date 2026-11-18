import Foundation

// 실행 시 환경변수 DEVLINK_DEMO=1 (스킴 Run > Environment Variables) 이면 화면 확인용 상태를 띄운다.
extension WindowState {
    /// 화면 확인용: 프로젝트 화면 + 환경 탭들 + 분할 화면을 미리 띄운다.
    func loadDemo() {
        projects = SampleData.projects
        let shop = projects.first { $0.name == "Sample Shop" }!
        let left = panes[0]
        left.tabs[0].content = .start(.project(shop.id))
        let products = makePageTab(project: shop, env: shop.envs[1], path: "/products")
        products.pageTitle = "Products | Sample Shop"
        left.add(products)
        // prd 탭에서 stg 로 이동한 상태 → "다른 환경 방문 중"
        let tangled = makePageTab(project: shop, env: shop.envs[3], path: "/")
        tangled.currentURL = URL(string: "https://stg.example.com/login")
        tangled.pageTitle = "Login | Sample Shop (STG)"
        left.add(tangled)
        left.selectedTabID = left.tabs[2].id
        let right = Pane()
        right.tabs[0] = makePageTab(project: shop, env: shop.envs[2], path: "/cart")
        right.tabs[0].pageTitle = "Cart | Sample Shop"
        right.selectedTabID = right.tabs[0].id
        // 외부 방문 중
        let external = makePageTab(project: shop, env: shop.envs[0], path: "/")
        external.currentURL = URL(string: "https://developer.apple.com/documentation/webkit")
        external.pageTitle = "WebKit | Apple Developer Documentation"
        right.tabs.append(external)
        right.selectedTabID = external.id   // 실제 사이트가 뜨는지 확인용
        let gsc = makePageTab(project: shop, env: shop.envs[4], path: "/")
        gsc.pageTitle = "GS Verification | Sample Shop"
        right.tabs.append(gsc)
        panes.append(right)
    }
}
