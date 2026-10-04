import CryptoKit
import Foundation

/// Versioned, opaque notes marker. Only a full marker (with optional provider whitespace) is recognized.
public struct Ownership: Sendable {
    public struct Marker: Equatable, Sendable {
        public let installationID: UUID
        public let linkID: String
        public let targetID: String
        /// Hashed contributing calendar identities preserve safety when a policy disappears.
        public let sourceIDs: Set<String>
    }

    public let installationID: UUID

    public init(installationID: UUID) {
        self.installationID = installationID
    }

    /// `linkID` must be a SHA-256 hex digest. Names and provider IDs are never serialized into notes.
    public func encode(linkID: String, targetIdentity: String, sourceIdentities: Set<String>) throws -> String {
        guard Self.isDigest(linkID) else { throw OwnershipError.invalidLinkID }
        guard !sourceIdentities.isEmpty else { throw OwnershipError.missingSourceIdentities }
        let sources = sourceIdentities.map(calendarDigest).sorted().joined(separator: ",")
        return "belovodie-busy:v1:\(installationID.uuidString.lowercased()):\(calendarDigest(targetIdentity)):\(linkID.lowercased()):\(sources)"
    }

    public static func decode(_ value: String?) -> Marker? {
        guard let value else { return nil }
        let compact = value.filter { !$0.isWhitespace }
        let parts = compact.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "belovodie-busy", parts[1] == "v1",
              let installation = UUID(uuidString: parts[2]), isDigest(parts[3]), isDigest(parts[4]) else {
            return nil
        }
        let sources = parts[5].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !sources.isEmpty, sources.allSatisfy(isDigest) else { return nil }
        return Marker(installationID: installation, linkID: parts[4].lowercased(),
                      targetID: parts[3].lowercased(), sourceIDs: Set(sources.map { $0.lowercased() }))
    }

    func calendarDigest(_ identity: String) -> String {
        digest(["calendar", identity])
    }

    func linkDigest(targetIdentity: String, eventIdentities: Set<String>, fragment: Int) -> String {
        digest(["link", targetIdentity, String(fragment)] + eventIdentities.sorted())
    }

    private func digest(_ components: [String]) -> String {
        let fields = [installationID.uuidString.lowercased()] + components
        let input = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }
}

public enum OwnershipError: Error, Equatable {
    case invalidLinkID
    case missingSourceIdentities
}
