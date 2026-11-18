import Foundation
import Security
import WebKit

/// 지금 탭 페이지의 SSL 인증서 요약 (잎 인증서의 만료일·발급자 + 체인). https 가 아니거나 신뢰 정보가 없으면 만들지 못한다.
struct CertificateInfo {
    /// 만료까지 남은 일수 기준: 25일 이하 주황, 15일 이하(만료 포함) 빨강
    static let warnDays = 25
    static let criticalDays = 15

    enum Level { case ok, warning, critical }

    let notAfter: Date
    let issuer: String
    let chain: [SecCertificate]

    init?(webView: WKWebView?) {
        guard let webView, webView.url?.scheme?.lowercased() == "https", let trust = webView.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1IssuerName] as CFArray, nil) as? [String: Any],
              let end = (values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? NSNumber
        else { return nil }
        self.chain = chain
        notAfter = Date(timeIntervalSinceReferenceDate: end.doubleValue)
        // 발급자: 조직 이름(2.5.4.10), 없으면 일반 이름(2.5.4.3), 없으면 중간 인증서 이름
        let parts = ((values[kSecOIDX509V1IssuerName as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]]) ?? []
        func part(_ oid: String) -> String? {
            parts.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid }?[kSecPropertyKeyValue as String] as? String
        }
        issuer = part("2.5.4.10") ?? part("2.5.4.3") ?? (chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil) ?? ""
    }

    /// 만료까지 남은 일수 (올림, 이미 지났으면 0 이하)
    var daysLeft: Int { Int(ceil(notAfter.timeIntervalSinceNow / 86_400)) }
    var isExpired: Bool { notAfter <= Date() }

    var level: Level {
        if isExpired || daysLeft <= Self.criticalDays { return .critical }
        return daysLeft <= Self.warnDays ? .warning : .ok
    }

    /// 자물쇠 옆 글자 (경고 단계에서만): "12d" · "Expired"
    var badge: String? {
        guard level != .ok else { return nil }
        return isExpired ? String(localized: "Expired") : "\(daysLeft)d"
    }

    var tooltip: String {
        let date = notAfter.formatted(.iso8601.year().month().day())
        let when = isExpired ? String(localized: "Expired \(date)") : String(localized: "Expires \(date) (\(daysLeft) days left)")
        return issuer.isEmpty ? when : when + " · " + String(localized: "Issued by \(issuer)")
    }
}
