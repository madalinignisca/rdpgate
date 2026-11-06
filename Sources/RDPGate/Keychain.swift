import Foundation
import Security

/// Passwords live in the login keychain, never in config.json.
///
/// Stored as a generic password keyed by a UUID, so renaming a host or user does
/// not orphan the entry. Items are marked `kSecAttrAccessibleWhenUnlocked`,
/// meaning they are readable only while the Mac is unlocked and are excluded
/// from iCloud keychain sync.
enum Keychain {

    /// Target passwords and shared-identity passwords live under different
    /// services. UUIDs would not collide anyway; the split exists so that no
    /// target-side delete can ever reach a shared secret. `.target` keeps the
    /// original service name, so items saved by earlier builds still resolve.
    enum Kind {
        case target
        case identity

        var service: String {
            switch self {
            case .target:   return "local.rdpgate"
            case .identity: return "local.rdpgate.identity"
            }
        }
    }

    static func query(_ id: UUID, kind: Kind) -> [String: Any] {
        query(account: id.uuidString, service: kind.service)
    }

    static func query(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ password: String, for id: UUID, kind: Kind = .target) -> Bool {
        save(password, account: id.uuidString, service: kind.service)
    }

    /// Update in place, add only when nothing is there yet.
    ///
    /// Not delete-then-add: if the add failed after the delete, rotating a
    /// password would silently lose the old one. With update-first, a failed
    /// write leaves the previous password intact.
    static func save(_ password: String, account: String, service: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let match = query(account: account, service: service)
        let changes: [String: Any] = [kSecValueData as String: data]

        let updated = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem {
            // Created between our update and add; one more update settles it.
            return SecItemUpdate(match as CFDictionary, changes as CFDictionary) == errSecSuccess
        }
        return added == errSecSuccess
    }

    static func load(for id: UUID, kind: Kind = .target) -> String? {
        load(account: id.uuidString, service: kind.service)
    }

    static func load(account: String, service: String) -> String? {
        var q = query(account: account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// True when the item is gone afterwards — including when it never existed,
    /// so callers can treat `false` as a real failure worth reporting.
    @discardableResult
    static func delete(for id: UUID, kind: Kind = .target) -> Bool {
        delete(account: id.uuidString, service: kind.service)
    }

    @discardableResult
    static func delete(account: String, service: String) -> Bool {
        let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func exists(for id: UUID, kind: Kind = .target) -> Bool {
        var q = query(id, kind: kind)
        q[kSecReturnData as String] = false
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
}
