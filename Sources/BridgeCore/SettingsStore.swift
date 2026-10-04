import Foundation

public struct BridgeSettings: Codable, Equatable, Sendable {
    public let version: Int
    public let installationID: UUID
    public var policies: [CalendarPolicy]
    public init(installationID: UUID = UUID(), policies: [CalendarPolicy] = []) {
        version = 1
        self.installationID = installationID
        self.policies = policies
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
public enum SettingsStoreError: Error, Equatable { case unsupportedVersion, duplicatePolicy }
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
        guard Set(settings.policies.map(\.identity)).count == settings.policies.count else { throw SettingsStoreError.duplicatePolicy }
    }
}
