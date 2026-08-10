import Foundation

/// The pasteboard facts needed for a privacy decision, independent of AppKit.
public struct PasteboardChange: Sendable, Equatable {
    public let typeIdentifiers: Set<String>
    public let sourceBundleID: String?
    public let fingerprint: String

    public init(typeIdentifiers: Set<String>, sourceBundleID: String? = nil, fingerprint: String) {
        self.typeIdentifiers = typeIdentifiers
        self.sourceBundleID = sourceBundleID
        self.fingerprint = fingerprint
    }
}

public struct PrivacySettings: Sendable, Equatable {
    public var isPaused: Bool
    public var excludedBundleIDs: Set<String>
    public var seenFingerprints: Set<String>

    public init(
        isPaused: Bool = false,
        excludedBundleIDs: Set<String> = [],
        seenFingerprints: Set<String> = []
    ) {
        self.isPaused = isPaused
        self.excludedBundleIDs = excludedBundleIDs
        self.seenFingerprints = seenFingerprints
    }
}

public enum PrivacyFilter {
    public static let concealedTypeIdentifier = "org.nspasteboard.ConcealedType"
    public static let transientTypeIdentifier = "org.nspasteboard.TransientType"

    public static let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword7",
        "com.lastpass.lastpass",
        "com.dashlane.dashlane",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess"
    ]

    public static func shouldRecord(change: PasteboardChange, settings: PrivacySettings) -> Bool {
        guard !settings.isPaused else { return false }

        let normalizedTypes = Set(change.typeIdentifiers.map(normalized))
        guard !normalizedTypes.contains(normalized(concealedTypeIdentifier)),
              !normalizedTypes.contains(normalized(transientTypeIdentifier)) else {
            return false
        }

        if let sourceBundleID = change.sourceBundleID.map(normalized) {
            let excludedBundleIDs = Set((passwordManagerBundleIDs.union(settings.excludedBundleIDs)).map(normalized))
            guard !excludedBundleIDs.contains(sourceBundleID) else { return false }
        }

        return true
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
