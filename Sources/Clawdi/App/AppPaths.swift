import Foundation

struct AppPaths: Sendable {
    let base: URL
    let settings: URL
    let pattern: URL
    let customPresets: URL
    let hooks: URL

    static let appName = "Clawdi"

    static func resolve(fileManager: FileManager = .default) throws -> AppPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = support.appendingPathComponent(appName, isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let hooks = base.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
        return AppPaths(
            base: base,
            settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: hooks
        )
    }

    func installedHookHelper(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> URL? {
        guard
            let executable = bundle.executableURL,
            fileManager.fileExists(atPath: executable.path)
        else {
            return nil
        }
        return executable
    }
}

enum LicenseGateResult: Equatable, Sendable { case ok }

protocol LicenseGate: Sendable { func evaluate() -> LicenseGateResult }

struct AlwaysAllowLicenseGate: LicenseGate { func evaluate() -> LicenseGateResult { .ok } }

struct JSONFileStore<Value: Codable> {
    var url: URL
    var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    var decoder = JSONDecoder()

    func load(default defaultValue: @autoclosure () -> Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return defaultValue() }
        return (try? decoder.decode(Value.self, from: data)) ?? defaultValue()
    }

    func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
