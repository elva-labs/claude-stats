import Foundation
import Security

/// Reads the OAuth access token that Claude Code stores in the login keychain.
///
/// We deliberately only *read* it. Claude Code owns the refresh cycle and writes
/// the fresh token back to the same item, so re-reading on every poll is enough
/// to stay current without us ever touching the refresh token.
enum Keychain {
    static let service = "Claude Code-credentials"

    enum TokenError: LocalizedError {
        case notFound
        case denied(OSStatus)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude Code credentials in the keychain. Run `claude` and sign in."
            case .denied(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain access denied (\(msg)). Click “Always Allow” when macOS asks."
            case .malformed:
                return "Claude Code credentials are in an unexpected format."
            }
        }
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    /// The current access token, plus its expiry (if the stored blob has one).
    static func accessToken() throws -> (token: String, expiresAt: Date?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw TokenError.notFound
        default:
            throw TokenError.denied(status)
        }

        guard let data = item as? Data else { throw TokenError.malformed }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let creds = try? decoder.decode(Credentials.self, from: data) else {
            throw TokenError.malformed
        }

        let expiry = creds.claudeAiOauth.expiresAt.map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return (creds.claudeAiOauth.accessToken, expiry)
    }
}
