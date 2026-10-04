import Foundation

public struct BridgeSettings: Codable, Equatable, Sendable {
    public let version: Int
    public let installationID: UUID
    public var policies: [CalendarPolicy]
    public var lookbackDays: Int
    public var lookaheadDays: Int
    public init(installationID: UUID = UUID(), policies: [CalendarPolicy] = [], lookbackDays: Int = 7, lookaheadDays: Int = 90) {
        version = 1
        self.installationID = installationID
        self.policies = policies
        self.lookbackDays = lookbackDays
        self.lookaheadDays = lookaheadDays
    }
    private enum CodingKeys: String, CodingKey { case version, installationID, policies, lookbackDays, lookaheadDays }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        installationID = try values.decode(UUID.self, forKey: .installationID)
        policies = try values.decode([CalendarPolicy].self, forKey: .policies)
        lookbackDays = try values.decodeIfPresent(Int.self, forKey: .lookbackDays) ?? 7
        lookaheadDays = try values.decodeIfPresent(Int.self, forKey: .lookaheadDays) ?? 90
    }
    /// Missing inventory entries remain selected: absence is not a confirmed disable/removal.
    public mutating func discover(_ inventory: [CalendarDescriptor]) {
        var known = Set(policies.map(\.identity))
        for calendar in inventory where calendar.localRead != .confirmedRemoved {
            if known.insert(calendar.identity).inserted {
                policies.append(CalendarPolicy(sourceID: calendar.sourceID, calendarID: calendar.calendarID,
                                               owner: calendar.owner, label: calendar.name))
            }
        }
    }
}
public enum SettingsStoreError: Error, Equatable { case unsupportedVersion, duplicatePolicy, invalidQueryWindow }
public struct SettingsStore: Sendable {
    public let directoryURL: URL
    public init(directoryURL: URL) { self.directoryURL = directoryURL }
    private var storage: AtomicStore { AtomicStore(fileURL: directoryURL.appendingPathComponent("settings.json")) }
    /// A first successful load persists the installation ID before any provider write is possible.
    public func load() throws -> BridgeSettings {
        guard let data = try storage.load() else {
            let settings = BridgeSettings()
            try save(settings)
            return settings
        }
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: data)
        try validate(settings)
        return settings
    }
    public func save(_ settings: BridgeSettings) throws {
        try validate(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.save(encoder.encode(settings))
    }
    private func validate(_ settings: BridgeSettings) throws {
        guard settings.version == 1 else { throw SettingsStoreError.unsupportedVersion }
        guard (0...365).contains(settings.lookbackDays), (1...365).contains(settings.lookaheadDays) else { throw SettingsStoreError.invalidQueryWindow }
        guard Set(settings.policies.map(\.identity)).count == settings.policies.count else { throw SettingsStoreError.duplicatePolicy }
    }
}
