import Foundation

/// Reads the OAuth access token that Claude Code stores in the login keychain.
///
/// The lookup shells out to `/usr/bin/security` instead of calling the Security
/// framework directly. Claude Code writes the item through that same binary, so
/// `security` is already on the item's access list and the read never triggers
/// the "wants to access" dialog — not after a rebuild (which changes our ad-hoc
/// code identity), and not after Claude Code recreates the item on a token
/// refresh (which resets any "Always Allow" granted to us directly).
///
/// We deliberately only *read* it. Claude Code owns the refresh cycle and writes
/// the fresh token back to the same item, so re-reading on every poll is enough
/// to stay current without us ever touching the refresh token.
enum Keychain {
    static let service = "Claude Code-credentials"

    enum TokenError: LocalizedError {
        case notFound
        case lookupFailed(Int32, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude Code credentials in the keychain. Run `claude` and sign in."
            case .lookupFailed(let code, let detail):
                let suffix = detail.isEmpty ? "" : ": \(detail)"
                return "Keychain lookup failed (exit \(code))\(suffix)"
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw TokenError.lookupFailed(-1, error.localizedDescription)
        }
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        switch process.terminationStatus {
        case 0:
            break
        case 44: // how security(1) reports errSecItemNotFound
            throw TokenError.notFound
        default:
            let detail = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TokenError.lookupFailed(process.terminationStatus, detail)
        }

        guard let payload = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)
        else { throw TokenError.malformed }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let creds = try? decoder.decode(Credentials.self, from: payload) else {
            throw TokenError.malformed
        }

        let expiry = creds.claudeAiOauth.expiresAt.map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return (creds.claudeAiOauth.accessToken, expiry)
    }
}
