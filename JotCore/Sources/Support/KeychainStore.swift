// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Security

/// API-key storage per TN3137: SecItem + data-protection keychain when the build
/// carries the keychain-access-groups entitlement (provisioned/notarized builds),
/// with a graceful fallback to the login keychain for dev and fork builds that
/// lack it (errSecMissingEntitlement, -34018). Never UserDefaults/JSON
/// (Superwhisper's documented failure).
public enum KeychainStore {
    private static let service = "com.ammaar.jot"
    private static let account = "gemini-api-key"

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public static func loadAPIKey() -> String? {
        if let cached = cache.value { return cached.isEmpty ? nil : cached }
        var query = baseQuery(dataProtection: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            let key = String(data: data, encoding: .utf8)
            cache.value = key ?? ""
            return key
        }
        let key = SecurityTool.run(["find-generic-password", "-s", service, "-a", account, "-w"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cache.value = key ?? ""
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// Optional Groq key for faster correction rewrites. Login keychain only,
    /// read and written through `security` like the Gemini key.
    public static func loadGroqKey() -> String? {
        if let cached = groqCache.value { return cached.isEmpty ? nil : cached }
        let key = SecurityTool.run(["find-generic-password", "-s", service, "-a", "groq-api-key", "-w"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        groqCache.value = key ?? ""
        return (key?.isEmpty ?? true) ? nil : key
    }

    @discardableResult
    public static func saveGroqKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = SecurityTool.run(["delete-generic-password", "-s", service, "-a", "groq-api-key"])
            groqCache.value = ""
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "groqKey")
            return true
        }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let command = "add-generic-password -U -s \(service) -a groq-api-key -l \"Jot — Groq API key\" -T /usr/bin/security -w \"\(escaped)\"\n"
        guard SecurityTool.run(["-i"], stdin: command) != nil else {
            Log.permissions.error("KeychainStore: Groq key save FAILED")
            return false
        }
        groqCache.value = trimmed
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "groqKey")
        return true
    }

    private static let groqCache = Cache()

    /// Builds signed without an Apple team ID get a new keychain partition on
    /// every rebuild, so reading the login keychain directly asks for the
    /// password after each update. Apple's `security` tool keeps a stable
    /// identity, so login-keychain reads and writes go through it.
    private enum SecurityTool {
        static func run(_ arguments: [String], stdin: String? = nil) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            let input = Pipe()
            if stdin != nil { process.standardInput = input }
            do {
                try process.run()
            } catch {
                Log.permissions.error("KeychainStore: couldn't run security — \(String(describing: error), privacy: .public)")
                return nil
            }
            if let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static let cache = Cache()

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        deleteAPIKey()
        var attributes = baseQuery(dataProtection: true)
        attributes[kSecAttrLabel as String] = "Jot — Gemini API key"
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            Log.permissions.info("KeychainStore: key saved (data-protection keychain)")
        } else if status == errSecMissingEntitlement {
            // Unprovisioned build: the login keychain, written by `security` so
            // the item trusts it and later reads never prompt. The key travels
            // on stdin, never on a command line.
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let command = "add-generic-password -U -s \(service) -a \(account) -l \"Jot — Gemini API key\" -T /usr/bin/security -w \"\(escaped)\"\n"
            guard SecurityTool.run(["-i"], stdin: command) != nil else {
                Log.permissions.error("KeychainStore: login-keychain save FAILED")
                return false
            }
            Log.permissions.info("KeychainStore: key saved (login keychain)")
        } else {
            Log.permissions.error("KeychainStore: save failed (\(status))")
            return false
        }
        cache.value = key
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        return true
    }

    @discardableResult
    public static func deleteAPIKey(notify: Bool = false) -> Bool {
        cache.value = ""
        var deleted = SecItemDelete(baseQuery(dataProtection: true) as CFDictionary) == errSecSuccess
        if SecurityTool.run(["delete-generic-password", "-s", service, "-a", account]) != nil {
            deleted = true
        }
        // saveAPIKey's internal delete-before-add must not announce "key removed"
        // mid-save — only user-initiated removal notifies.
        if deleted, notify {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        }
        return deleted
    }

    /// Dev bootstrap until onboarding (M7): if ~/.config/jot/apikey.dev
    /// exists, migrate its contents into the Keychain and DELETE the file. Lets
    /// contributors seed a key without any UI, without leaving plaintext behind.
    public static func migrateDevKeyFileIfPresent() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jot/apikey.dev")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if saveAPIKey(key) {
            try? FileManager.default.removeItem(at: fileURL)
            Log.permissions.info("KeychainStore: migrated dev key file into Keychain (file deleted)")
        }
    }
}
