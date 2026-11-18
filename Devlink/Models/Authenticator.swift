import Foundation
import LocalAuthentication

/// 본인 인증 (Touch ID, 안 되면 Mac 로그인 암호). 테스트·데모에서는 묻지 않고 통과한다.
enum Authenticator {
    private static var bypass: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["DEVLINK_DEMO"] != nil
    }

    /// 인증을 쓸 수 없으면(암호 없는 Mac 등) 잠금을 걸 수 없다.
    static var available: Bool { bypass || LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    static func authenticate(reason: String, _ done: @escaping (Bool) -> Void) {
        guard !bypass else { done(true); return }
        Task {
            let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
            done(ok)
        }
    }
}
