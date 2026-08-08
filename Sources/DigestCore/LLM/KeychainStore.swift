import Foundation
import Security

public enum KeychainError: LocalizedError, Equatable {
    case status(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(op, status):
            "Keychain \(op) failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
        }
    }
}

/// The Anthropic API key in the login Keychain (generic password item).
public enum KeychainStore {
    public static let anthropicService = "com.brainmaxxing.anthropic"

    /// How a Keychain read may behave when macOS wants to ask the user.
    public enum LookupMode: Sendable {
        /// Normal behaviour: macOS may show the "allow access" dialog (interactive CLI runs, the app).
        case interactive
        /// Unattended runs (`run --if-due`, launchd): never show UI; an item that needs it throws
        /// `LLMError.keychainInteractionRequired` at once.
        case nonInteractive
    }

    /// Returns the password stored under `service`, or nil if there is none.
    public static func read(service: String) -> String? { try? read(service: service, mode: .interactive) }

    /// Returns the password stored under `service`, or nil if there is none. In `.nonInteractive` mode an item that
    /// would need a dialog throws `LLMError.keychainInteractionRequired` instead of blocking.
    public static func read(service: String, mode: LookupMode) throws -> String? {
        var item: CFTypeRef?
        let query = readQuery(service: service, mode: mode) as CFDictionary
        let status = mode == .nonInteractive
            ? (LegacyKeychain.self as any LegacyKeychainUI.Type).copyMatchingWithoutUI(query, &item)
            : SecItemCopyMatching(query, &item)
        try check(status, mode: mode)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    static func readQuery(service: String, mode: LookupMode) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if mode == .nonInteractive {
            // kSecUseAuthenticationUI: kSecUseAuthenticationUIFail, spelled by value because the symbols are
            // deprecated (a warning in every build). It alone does NOT stop the login-keychain "allow access" dialog
            // (checked on macOS 26); `LegacyKeychain` does that.
            query[authenticationUIKey] = authenticationUIFail
        }
        return query
    }

    static let authenticationUIKey = "u_AuthUI"
    static let authenticationUIFail = "u_AuthUIF"

    /// Non-interactive mode: a status meaning "the user would have to be asked" becomes a typed error.
    static func check(_ status: OSStatus, mode: LookupMode) throws {
        guard mode == .nonInteractive, status == errSecInteractionNotAllowed || status == errSecAuthFailed else { return }
        throw LLMError.keychainInteractionRequired
    }

    /// Adds or replaces the Anthropic key (service `com.brainmaxxing.anthropic`).
    public static func saveAnthropicKey(_ key: String) throws { try save(key, service: anthropicService) }

    /// Removes the Anthropic key; no error if there is none.
    public static func deleteAnthropicKey() throws { try delete(service: anthropicService) }

    /// Whether an Anthropic key is stored. Never reads the value.
    public static func hasAnthropicKey() -> Bool { exists(service: anthropicService) }

    // Service-parameterized so tests can use a throwaway item instead of the real one.

    static func save(_ value: String, service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.status("update", updated) }
        var add = query
        add[kSecValueData as String] = data
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status("add", added) }
    }

    static func delete(service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status("delete", status) }
    }

    static func exists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// `ANTHROPIC_API_KEY` from the environment first (both modes), then Keychain read in `mode`.
    public static func resolveAnthropicKey(
        mode: LookupMode = .interactive,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: ((String) throws -> String?)? = nil
    ) throws -> String {
        if let key = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        let lookup = keychain ?? { try read(service: $0, mode: mode) }
        if let key = try lookup(anthropicService) { return key }
        throw LLMError.missingAPIKey
    }
}

/// `SecKeychainSetUserInteractionAllowed(false)` is the only switch found that stops the login-keychain
/// "allow access" dialog: with `kSecUseAuthenticationUIFail` or `LAContext.interactionNotAllowed` alone a read from an
/// untrusted binary still blocked on the dialog (macOS 26); with it, the read returns `errSecAuthFailed` at once.
/// The API is deprecated; calling it through a protocol witness keeps the build free of deprecation warnings.
/// The flag is process-wide, so it is restored right after the read (the CLI reads the key once, before any task).
private protocol LegacyKeychainUI {
    static func copyMatchingWithoutUI(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus
}

private enum LegacyKeychain: LegacyKeychainUI {
    @available(macOS, deprecated: 10.10)
    static func copyMatchingWithoutUI(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return SecItemCopyMatching(query, &result)
    }
}
