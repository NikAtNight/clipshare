import Foundation
import Security

public enum TokenStore {
    private static let service = "app.talix.clipshare"
    private static let account = "owner-token"

    public static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw TokenStoreError(status) }
        return token
    }

    public static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TokenStoreError(update) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw TokenStoreError(add) }
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TokenStoreError(status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public struct TokenStoreError: Error, LocalizedError {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}

public struct ServerConfig: Sendable {
    public var baseURL: URL {
        didSet { UserDefaults.standard.set(baseURL.absoluteString, forKey: "serverBaseURL") }
    }

    public init(baseURL: URL? = nil) { self.baseURL = baseURL ?? ServerConfig.savedURL }

    private static var savedURL: URL {
        guard let value = UserDefaults.standard.string(forKey: "serverBaseURL"), let url = URL(string: value) else {
            return URL(string: "https://clips.talix.app") ?? URL(fileURLWithPath: "/")
        }
        return url
    }
}
