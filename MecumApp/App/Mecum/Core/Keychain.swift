//
//  Keychain.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Security

/// API keys live in the login keychain, never in UserDefaults.
///
/// One item per provider, under the service below and the account a
/// connection names as its `credentialReference`. The team's connection card
/// and the Settings window read and write the same items, so a key entered
/// once serves both: they are one person's key to one provider, in one app.
enum Keychain {

    private static let service = "dev.forte.Mecum"

    /// A write the keychain refused. It carries the status and never the value.
    struct WriteFailure: Error, CustomStringConvertible {

        let status: OSStatus

        var description: String {
            let message = SecCopyErrorMessageString(
                status,
                nil
            )
            return (message as String?) ?? "keychain status \(status)"
        }
    }

    static func string(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String      : kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String : true,
            kSecMatchLimit as String : kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let found = SecItemCopyMatching(
            query as CFDictionary,
            &item
        )
        guard found == errSecSuccess, let data = item as? Data else { return "" }

        return String(
            decoding: data,
            as      : UTF8.self
        )
    }

    /// Replaces the item, or removes it when `value` is empty. Throws when the
    /// keychain refuses, so a key that was not kept is never reported as kept.
    static func set(
        _ value    : String,
        for account: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String      : kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw WriteFailure(status: deleted) }
        guard !value.isEmpty else { return }

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        let added = SecItemAdd(
            item as CFDictionary,
            nil
        )
        guard added == errSecSuccess else { throw WriteFailure(status: added) }
    }
}
