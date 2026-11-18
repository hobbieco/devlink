import CryptoKit
import Foundation
import Security

/// 계정 비밀번호. 앱 파일에 암호화(AES-GCM)해 두고 키만 Keychain 에 둔다. 채울 때 따로 인증하지 않는다.
/// 계정 구분은 "도메인 id/계정 id" (복제한 도메인·이름을 바꾼 계정에는 따라가지 않는다).
/// 테스트·데모에서는 파일·Keychain 을 쓰지 않고 메모리에만 둔다.
final class PasswordStore {
    static let shared = PasswordStore()

    private var items: [String: String] = [:]
    private var loaded = false
    private let persists: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        persists = env["XCTestConfigurationFilePath"] == nil && env["DEVLINK_DEMO"] == nil
    }

    static func itemKey(domain: UUID, account: String) -> String { "\(domain.uuidString)/\(account)" }

    func has(domain: UUID, account: String) -> Bool { password(domain: domain, account: account) != nil }

    func password(domain: UUID, account: String) -> String? {
        load()
        return items[Self.itemKey(domain: domain, account: account)]
    }

    /// 비우면(nil·빈 문자열) 지운다.
    func set(_ password: String?, domain: UUID, account: String) {
        load()
        let key = Self.itemKey(domain: domain, account: account)
        if let password, !password.isEmpty { items[key] = password } else { items[key] = nil }
        save()
    }

    /// 도메인의 계정별 비밀번호 (저장된 것만). 설정 화면에 보낸다.
    func passwords(domain: UUID, accounts: [String]) -> [String: String] {
        load()
        var out: [String: String] = [:]
        for a in accounts { out[a] = items[Self.itemKey(domain: domain, account: a)] }
        return out
    }

    /// 여러 개를 한 번에 (itemKey → 비밀번호, 비면 지움). 바뀐 것이 있을 때만 저장한다.
    func apply(_ changes: [String: String]) {
        load()
        var changed = false
        for (key, password) in changes where items[key] != (password.isEmpty ? nil : password) {
            items[key] = password.isEmpty ? nil : password
            changed = true
        }
        if changed { save() }
    }

    /// 없어진 도메인·계정의 비밀번호를 지운다.
    func prune(keeping valid: Set<String>) {
        load()
        let stale = items.keys.filter { !valid.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale { items[key] = nil }
        save()
    }

    // MARK: 파일

    private static var fileURL: URL { URL.applicationSupportDirectory.appending(path: "Devlink/passwords.bin") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // 저장한 적이 없으면 Keychain 도 읽지 않는다
        guard persists, let data = try? Data(contentsOf: Self.fileURL), let key = Self.encryptionKey(create: false),
              let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key),
              let dict = try? JSONDecoder().decode([String: String].self, from: plain) else { return }
        items = dict
    }

    private func save() {
        guard persists else { return }
        do {
            guard let key = Self.encryptionKey(create: true) else { throw CocoaError(.fileWriteUnknown) }
            let plain = try JSONEncoder().encode(items)
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Devlink: failed to save passwords: \(error)")
        }
    }

    // MARK: Keychain (암호화 키 하나)

    private static let keyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                                  kSecAttrService as String: "Devlink Passwords",
                                                  kSecAttrAccount as String: "encryption-key"]

    private static func encryptionKey(create: Bool) -> SymmetricKey? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        var add = keyQuery
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }
}
