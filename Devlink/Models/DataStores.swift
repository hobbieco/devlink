import Foundation
import WebKit

/// 탭 저장소: 항상 메모리에만 둔다 (탭·창을 닫거나 앱을 끝내면 사라진다). 파생 탭은 연 탭의 저장소를 그대로 쓴다.
enum DataStores {
    static func make() -> WKWebsiteDataStore { .nonPersistent() }

    /// 예전 버전(저장소 유지 옵션)이 디스크에 남긴 저장소를 지운다. 실행할 때마다 확인한다.
    static func removeLegacyStores() {
        Task { @MainActor in
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
            }
        }
    }
}

enum ClearKind: CaseIterable {
    case all, cookies, storage, cache

    var title: String {
        switch self {
        case .all: String(localized: "Clear All and Reload")
        case .cookies: String(localized: "Clear Cookies Only")
        case .storage: String(localized: "Clear Storage Only (Local · Session · IndexedDB)")
        case .cache: String(localized: "Clear Cache Only")
        }
    }

    var types: Set<String> {
        switch self {
        case .all: WKWebsiteDataStore.allWebsiteDataTypes()
        case .cookies: [WKWebsiteDataTypeCookies]
        case .storage: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                        WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]
        case .cache: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        }
    }
}
