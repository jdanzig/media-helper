import Foundation
import Security

/// Tiny wrapper around the iOS keychain for storing API keys.
///
/// Keys live under a single service name (the bundle id suffix) so they
/// don't collide with anything else and show up together if the user
/// inspects their keychain. Values are plain UTF-8 strings.
enum KeychainStore {

    /// Namespaces we store under. Keep this small — each case is one
    /// keychain item.
    enum Item: String, CaseIterable {
        case openAIAPIKey         = "openai.apiKey"
        case assemblyAIAPIKey     = "assemblyai.apiKey"
        case instagramSessionCookie = "instagram.sessionCookie"
    }

    private static let service = "com.example.MediaHelper.keys"

    static func save(_ value: String, for item: Item) throws {
        let data = Data(value.utf8)

        // Delete first: SecItemUpdate has awkward predicate handling and
        // delete+add is idempotent across "does this already exist" cases.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (\(status))"])
        }
    }

    static func load(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasValue(for item: Item) -> Bool {
        load(item) != nil
    }
}
