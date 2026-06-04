import Foundation

struct PatternPreset: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var createdAt: String
    var updatedAt: String
    var pattern: PatternModel
    var builtIn: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt, pattern }

    init(id: String, name: String, createdAt: String, updatedAt: String, pattern: PatternModel, builtIn: Bool = false) {
        self.id = id
        self.name = Self.cleanName(name)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pattern = pattern.sanitized()
        self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = Self.cleanName(try c.decodeIfPresent(String.self, forKey: .name) ?? "My preset")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        pattern = (try c.decodeIfPresent(PatternModel.self, forKey: .pattern) ?? .default).sanitized()
        builtIn = false
    }

    static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "My preset" : trimmed).prefix(60))
    }
}

struct CustomPresetsFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var presets: [PatternPreset] = []
}

struct PatternExport: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var app: String
    var exportedAt: String
    var preset: ExportPreset

    struct ExportPreset: Codable, Equatable, Sendable {
        var name: String
        var createdAt: String
        var updatedAt: String
        var pattern: PatternModel
    }
}

enum PresetImportError: Error, Equatable { case unsupportedApp, noPreset }

private struct ImportedPreset: Decodable {
    var name: String?
    var createdAt: String?
    var updatedAt: String?
    var pattern: PatternModel?
}

private struct ImportEnvelope: Decodable {
    var schemaVersion: Int?
    var app: String?
    var preset: ImportedPreset?
    var presets: [ImportedPreset]?
}

final class PresetStore {
    private let bundle: Bundle
    private let customURL: URL
    private(set) var builtIns: [PatternPreset] = []
    private(set) var custom: [PatternPreset] = []

    init(bundle: Bundle = .main, customURL: URL) {
        self.bundle = bundle
        self.customURL = customURL
        reload()
    }

    var all: [PatternPreset] { builtIns + custom }

    /// Pattern shipped for fresh installs (no saved `pattern.json`). Falls back to the bare
    /// `PatternModel.default` only if the built-in is somehow missing from the bundle.
    static let defaultPresetId = "brown-tabby"
    var defaultPattern: PatternModel {
        builtIns.first { $0.id == Self.defaultPresetId }?.pattern ?? .default
    }

    func reload() {
        builtIns = Self.loadBuiltIns(bundle: bundle)
        let file = JSONFileStore<CustomPresetsFile>(url: customURL).load(default: CustomPresetsFile())
        custom = file.presets.compactMap { preset in
            guard !preset.id.isEmpty else { return nil }
            return normalizedPreset(preset, builtIn: false)
        }
    }

    func saveCustom() throws {
        try JSONFileStore<CustomPresetsFile>(url: customURL).save(
            CustomPresetsFile(
                version: 1,
                presets: custom.map { p in
                    var q = p
                    q.builtIn = false
                    return q
                }))
    }

    @discardableResult
    func add(name: String, pattern: PatternModel, now: Date = Date()) throws -> PatternPreset {
        let stamp = ISO8601DateFormatter().string(from: now)
        let id = "custom-\(Int(now.timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(6)).lowercased())"
        var storedPattern = pattern.sanitized()
        storedPattern.selectedPresetId = id
        let preset = PatternPreset(
            id: id, name: uniqueName(name), createdAt: stamp, updatedAt: stamp, pattern: storedPattern, builtIn: false)
        custom.append(preset)
        try saveCustom()
        return preset
    }

    @discardableResult
    func update(id: String, name: String? = nil, pattern: PatternModel, now: Date = Date()) throws -> PatternPreset? {
        guard let idx = custom.firstIndex(where: { $0.id == id }) else { return nil }
        var storedPattern = pattern.sanitized()
        storedPattern.selectedPresetId = id
        if let name {
            custom[idx].name = uniqueName(name, excluding: id)
        }
        custom[idx].pattern = storedPattern
        custom[idx].updatedAt = ISO8601DateFormatter().string(from: now)
        try saveCustom()
        return custom[idx]
    }

    func rename(id: String, name: String) throws {
        guard let idx = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[idx].name = uniqueName(name, excluding: id)
        custom[idx].updatedAt = ISO8601DateFormatter().string(from: Date())
        try saveCustom()
    }

    func delete(id: String) throws {
        custom.removeAll { $0.id == id }
        try saveCustom()
    }

    func exportData(id: String, now: Date = Date()) throws -> Data? {
        guard let p = all.first(where: { $0.id == id }) else { return nil }
        let payload = PatternExport(
            schemaVersion: 2, app: "clawdi", exportedAt: ISO8601DateFormatter().string(from: now),
            preset: .init(name: p.name, createdAt: p.createdAt, updatedAt: p.updatedAt, pattern: p.pattern.sanitized()))
        return try JSONEncoder.stable.encode(payload)
    }

    @discardableResult
    func importData(_ data: Data, now: Date = Date()) throws -> [PatternPreset] {
        let decoder = JSONDecoder()
        let imported = try importedPresets(from: data, decoder: decoder)
        var added: [PatternPreset] = []
        for item in imported {
            guard let pattern = item.pattern else { continue }
            added.append(
                try addImported(
                    name: item.name, createdAt: item.createdAt, updatedAt: item.updatedAt, pattern: pattern, now: now))
        }
        if added.isEmpty { throw PresetImportError.noPreset }
        return added
    }

    func uniqueName(_ baseRaw: String, excluding id: String? = nil) -> String {
        let base = PatternPreset.cleanName(baseRaw)
        let names = Set(custom.filter { $0.id != id }.map(\.name))
        if !names.contains(base) { return base }
        for i in 1...999 {
            let suffix = " (\(i))"
            let prefix = String(base.prefix(max(0, 60 - suffix.count)))
            let candidate = "\(prefix)\(suffix)"
            if !names.contains(candidate) { return candidate }
        }
        return String("\(base)-\(Int(Date().timeIntervalSince1970))".prefix(60))
    }

    static func loadBuiltIns(bundle: Bundle) -> [PatternPreset] {
        let names: [(String, String, String)] = [
            ("black-cat", "Black cat", "black-cat"),
            ("white-cat", "White cat", "white-cat"),
            ("cheese-cat", "Cheese cat", "cheese-cat"),
            ("siamese-cat", "Siamese cat", "siamese-cat"),
            ("mackerel-tabby", "Mackerel tabby", "mackerel-tabby"),
            ("brown-tabby", "Brown tabby", "brown-tabby"),
            ("calico-cat", "Calico cat", "calico-cat"),
            ("russian-blue", "Russian Blue", "rusian-blue"),
        ]
        return names.compactMap { id, name, resource in
            guard
                let url = bundle.url(forResource: resource, withExtension: "json", subdirectory: "presets")
                    ?? bundle.url(forResource: resource, withExtension: "json"),
                let data = try? Data(contentsOf: url),
                var pattern = try? JSONDecoder().decode(PatternModel.self, from: data).sanitized()
            else { return nil }
            pattern.selectedPresetId = id
            return PatternPreset(id: id, name: name, createdAt: "", updatedAt: "", pattern: pattern, builtIn: true)
        }
    }

    func matchingPreset(for pattern: PatternModel) -> PatternPreset? {
        let sig = pattern.sanitized().signature()
        return all.first { $0.pattern.sanitized().signature() == sig }
    }

    private func normalizedPreset(_ preset: PatternPreset, builtIn: Bool) -> PatternPreset {
        var p = preset
        p.name = PatternPreset.cleanName(p.name)
        p.builtIn = builtIn
        p.pattern = p.pattern.sanitized()
        p.pattern.selectedPresetId = p.id
        return p
    }

    private func addImported(name: String?, createdAt: String?, updatedAt: String?, pattern: PatternModel, now: Date)
        throws -> PatternPreset
    {
        let stamp = ISO8601DateFormatter().string(from: now)
        let id = "custom-\(Int(now.timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(6)).lowercased())"
        var storedPattern = pattern.sanitized()
        storedPattern.selectedPresetId = id
        let preset = PatternPreset(
            id: id, name: uniqueName(name ?? "My preset"), createdAt: createdAt?.isEmpty == false ? createdAt! : stamp,
            updatedAt: updatedAt?.isEmpty == false ? updatedAt! : stamp, pattern: storedPattern, builtIn: false)
        custom.append(preset)
        try saveCustom()
        return preset
    }

    private func importedPresets(from data: Data, decoder: JSONDecoder) throws -> [ImportedPreset] {
        if let export = try? decoder.decode(PatternExport.self, from: data) {
            guard export.app.lowercased() == "clawdi" else {
                throw PresetImportError.unsupportedApp
            }
            return [
                ImportedPreset(
                    name: export.preset.name, createdAt: export.preset.createdAt, updatedAt: export.preset.updatedAt,
                    pattern: export.preset.pattern)
            ]
        }
        if let envelope = try? decoder.decode(ImportEnvelope.self, from: data) {
            if let app = envelope.app?.lowercased(), app != "clawdi" {
                throw PresetImportError.unsupportedApp
            }
            let presets = envelope.presets ?? envelope.preset.map { [$0] } ?? []
            if !presets.isEmpty { return presets }
        }
        if let presets = try? decoder.decode([ImportedPreset].self, from: data), !presets.isEmpty {
            return presets
        }
        if let file = try? decoder.decode(CustomPresetsFile.self, from: data), !file.presets.isEmpty {
            return file.presets.map {
                ImportedPreset(name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt, pattern: $0.pattern)
            }
        }
        throw PresetImportError.noPreset
    }
}

func clawdiPatternExportFilename(name: String) -> String {
    let safe = name.lowercased().replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "clawdi-pattern-\(safe.isEmpty ? "custom" : safe).json"
}
