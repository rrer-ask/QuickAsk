import Foundation

/// API keys in Application Support — no Keychain prompts.
enum SecretStore {
    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("QuickAsk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveAll(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func save(account: String, secret: String) throws {
        var all = loadAll()
        all[account] = secret
        try saveAll(all)
    }

    static func load(account: String) -> String? {
        let value = loadAll()[account]
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func delete(account: String) {
        var all = loadAll()
        all.removeValue(forKey: account)
        try? saveAll(all)
    }

    static var storagePathDescription: String {
        fileURL.path
    }
}
