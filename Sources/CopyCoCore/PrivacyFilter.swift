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

    public enum Decision: Sendable, Equatable {
        case record
        case skip(Reason)

        public var shouldRecord: Bool {
            if case .record = self { return true }
            return false
        }
    }

    public enum Reason: Sendable, Equatable {
        case paused
        case concealedOrTransient
        case excludedSource
    }

    public static func decide(change: PasteboardChange, settings: PrivacySettings) -> Decision {
        guard !settings.isPaused else { return .skip(.paused) }

        let normalizedTypes = Set(change.typeIdentifiers.map(normalized))
        if normalizedTypes.contains(normalized(concealedTypeIdentifier))
            || normalizedTypes.contains(normalized(transientTypeIdentifier)) {
            return .skip(.concealedOrTransient)
        }

        if let sourceBundleID = change.sourceBundleID.map(normalized) {
            let excludedBundleIDs = Set((passwordManagerBundleIDs.union(settings.excludedBundleIDs)).map(normalized))
            if excludedBundleIDs.contains(sourceBundleID) {
                return .skip(.excludedSource)
            }
        }

        return .record
    }

    public static func shouldRecord(change: PasteboardChange, settings: PrivacySettings) -> Bool {
        decide(change: change, settings: settings).shouldRecord
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
