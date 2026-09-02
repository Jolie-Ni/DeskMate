import Foundation
import DeskMateCore

/// Checks the API key store, because the two things that can go wrong with it
/// are both silent: a key saved world-readable, and an environment override
/// that stops overriding. Neither shows up in the UI.
///
/// Run against a scratch directory — it writes and deletes the real key file:
///
///     DESKMATE_STORAGE_DIR=$(mktemp -d) DeskMateFixture keystore-check
///
enum KeyStoreCheck {
    /// The file's permission bits, or nil if it isn't there.
    private static func mode() -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: APIKeyStore.fileURL.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue
    }

    static func run() {
        var ok = true
        func check(_ condition: Bool, _ description: String) {
            if condition {
                print("  ok   \(description)")
            } else {
                print("  FAIL \(description)")
                ok = false
            }
        }

        guard ProcessInfo.processInfo.environment["DESKMATE_STORAGE_DIR"] != nil else {
            FileHandle.standardError.write(
                "refusing to run against the real storage directory — set DESKMATE_STORAGE_DIR\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        try? APIKeyStore.clear()

        print("empty store")
        check(APIKeyStore.stored() == nil, "no saved key")
        check(!APIKeyStore.hasKey || APIKeyStore.isOverriddenByEnvironment,
              "hasKey is false unless the environment supplies one")

        print("round trip")
        let key = "sk-ant-api03-keystorecheck"
        do { try APIKeyStore.save(key) } catch {
            print("  FAIL save threw: \(error)"); exit(1)
        }
        check(APIKeyStore.stored() == key, "reads back exactly what was written")

        // The whole reason this is a file and not the Keychain is that the
        // permissions are ours to get right. 0600 or the design is a downgrade.
        check(mode() == 0o600, "mode is 0600 (got \(mode().map(String.init) ?? "nil"))")

        print("whitespace")
        try? APIKeyStore.save("  \(key)\n")
        check(APIKeyStore.stored() == key, "trims a pasted key's stray whitespace")

        // A file that was 0644 before an upgrade must not stay 0644 after one.
        print("overwrite")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: APIKeyStore.fileURL.path)
        try? APIKeyStore.save(key)
        check(mode() == 0o600, "re-tightens a loosened file to 0600")

        // daily-summary.sh exports ANTHROPIC_API_KEY unconditionally, so on a
        // machine with no shell key the launchd job arrives with it set to "".
        // If empty counted as "present", resolve() would return nothing and the
        // nightly prose would vanish with no error anywhere.
        print("environment precedence")
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        if envKey == nil || envKey!.isEmpty {
            check(APIKeyStore.fromEnvironment() == nil, "an empty env var reads as absent")
            check(APIKeyStore.resolve() == key, "resolve falls through to the file")
            check(APIKeyStore.hasKey, "hasKey sees the saved file")
            check(!APIKeyStore.isOverriddenByEnvironment, "not reported as overridden")
        } else {
            check(APIKeyStore.resolve() == envKey, "a set env var wins over the file")
            check(APIKeyStore.isOverriddenByEnvironment, "reported as overridden")
        }

        print("shape")
        check(APIKeyStore.looksLikeAnthropicKey("sk-ant-api03-x"), "accepts sk-ant-")
        check(!APIKeyStore.looksLikeAnthropicKey("sk-proj-x"), "rejects an OpenAI key")
        check(!APIKeyStore.looksLikeAnthropicKey(""), "rejects empty")
        check(APIKeyStore.redacted("sk-ant-api03-abcd1234").hasSuffix("1234"), "redaction keeps the tail")
        check(!APIKeyStore.redacted("sk-ant-api03-abcd1234").contains("api03"), "redaction hides the body")

        print("clear")
        try? APIKeyStore.clear()
        check(APIKeyStore.stored() == nil, "clear removes the file")
        check((try? APIKeyStore.clear()) != nil, "clearing twice is not an error")

        print(ok ? "keystore-check: PASS" : "keystore-check: FAIL")
        exit(ok ? 0 : 1)
    }
}
