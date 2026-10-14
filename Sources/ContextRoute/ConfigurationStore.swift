import Foundation

/// Owns disk writes. The model publishes a change only after this store saves it.
struct ConfigurationStore {
    struct Loaded {
        var configuration: RouterConfiguration
        var recoveredFromBackup = false
    }

    let configURL: URL
    var backupURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json") }

    init() {
        configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextRoute/config.json")
    }

    func load() throws -> Loaded {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                return Loaded(configuration: try read(backupURL), recoveredFromBackup: true)
            }
            return Loaded(configuration: RouterConfiguration())
        }
        do {
            return Loaded(configuration: try read(configURL))
        } catch {
            if let backup = try? read(backupURL) {
                return Loaded(configuration: backup, recoveredFromBackup: true)
            }
            throw error
        }
    }

    func read(_ url: URL) throws -> RouterConfiguration {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            throw StoreError("The settings file is too large.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw StoreError("The settings file is too large.") }
        let config = try JSONDecoder().decode(RouterConfiguration.self, from: data)
        try validate(config)
        return config
    }

    func save(_ config: RouterConfiguration, preserveDamagedFile: Bool = false) throws {
        try validate(config)
        let data = try encoded(config)
        let manager = FileManager.default
        try manager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: configURL.path) {
            let prior = try Data(contentsOf: configURL)
            let priorIsValid: Bool
            do {
                try validate(JSONDecoder().decode(RouterConfiguration.self, from: prior))
                priorIsValid = true
            } catch { priorIsValid = false }
            if priorIsValid {
                try prior.write(to: backupURL, options: .atomic)
            } else {
                guard preserveDamagedFile else { throw StoreError("Restore a backup or import settings before making changes.") }
                let retained = configURL.deletingLastPathComponent()
                    .appendingPathComponent("config.unreadable.\(UUID().uuidString).json")
                try prior.write(to: retained, options: .atomic)
            }
        } else {
            // Keep a recoverable copy even before the second settings change.
            try data.write(to: backupURL, options: .atomic)
        }
        try data.write(to: configURL, options: .atomic)
    }

    func export(_ config: RouterConfiguration, to url: URL) throws {
        try validate(config)
        try encoded(config).write(to: url, options: .atomic)
    }

    private func encoded(_ config: RouterConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    private func validate(_ config: RouterConfiguration) throws {
        guard [1, 2].contains(config.schemaVersion ?? 1) else { throw StoreError("This settings file was created by a newer version of ContextRoute.") }
        let targets = config.sourceRoutes.map(\.target) + config.websiteRoutes.map(\.target) + [config.fallbackTarget].compactMap { $0 }
        let routeIDs = config.sourceRoutes.map(\.id) + config.websiteRoutes.map(\.id)
        let patterns = config.websiteRoutes.compactMap { $0.pattern.normalized }
        guard Set(config.sourceRoutes.map(\.id)).count == config.sourceRoutes.count,
              Set(routeIDs).count == routeIDs.count,
              patterns.count == config.websiteRoutes.count,
              Set(patterns).count == patterns.count,
              Set(config.sourceRoutes.map(\.sourceBundleIdentifier)).count == config.sourceRoutes.count,
              Set(config.urlAppOverrides.map(\.id)).count == config.urlAppOverrides.count,
              config.sourceRoutes.allSatisfy({ !$0.sourceBundleIdentifier.isEmpty && !$0.browserBundleIdentifier.isEmpty }),
              config.fallbackBrowserBundleIdentifier != Bundle.main.bundleIdentifier,
              config.sourceRoutes.allSatisfy({ $0.browserBundleIdentifier != Bundle.main.bundleIdentifier }),
              targets.allSatisfy({ !$0.browserBundleIdentifier.isEmpty && $0.browserBundleIdentifier != Bundle.main.bundleIdentifier
                  && ($0.profileIdentifier.map { !$0.isEmpty } ?? true) }),
              config.fallbackProfileIdentifier == nil || config.fallbackBrowserBundleIdentifier != nil,
              config.urlAppOverrides.allSatisfy({ item in
                  !item.id.isEmpty && item.candidateBundleIdentifiers.allSatisfy { $0 != Bundle.main.bundleIdentifier }
              }) else {
            throw StoreError("The settings file contains invalid or duplicate rules.")
        }
    }
}

private struct StoreError: LocalizedError {
    let key: String
    init(_ key: String) { self.key = key }
    var errorDescription: String? { ContextRouteLocalization.string(key) }
}
