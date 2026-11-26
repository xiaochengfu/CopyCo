import Foundation
import XCTest
@testable import CopyCoCore

final class PrivacyFilterTests: XCTestCase {
    func testRejectsConcealedAndTransientPasteboards() {
        XCTAssertFalse(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text", PrivacyFilter.concealedTypeIdentifier], fingerprint: "concealed"),
            settings: PrivacySettings()
        ))
        XCTAssertFalse(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: [PrivacyFilter.transientTypeIdentifier], fingerprint: "transient"),
            settings: PrivacySettings()
        ))
        XCTAssertEqual(
            PrivacyFilter.decide(
                change: PasteboardChange(
                    typeIdentifiers: ["public.utf8-plain-text", PrivacyFilter.concealedTypeIdentifier],
                    fingerprint: "concealed"
                ),
                settings: PrivacySettings()
            ),
            .skip(.concealedOrTransient)
        )
    }

    func testRejectsExcludedBundleIDWithoutCaseSensitivity() {
        let settings = PrivacySettings(excludedBundleIDs: ["COM.EXAMPLE.PrivateApp"])

        XCTAssertFalse(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.example.privateapp", fingerprint: "private"),
            settings: settings
        ))
    }

    func testRejectsBuiltInPasswordManagerBundleID() {
        XCTAssertFalse(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password", fingerprint: "password"),
            settings: PrivacySettings()
        ))
        XCTAssertEqual(
            PrivacyFilter.decide(
                change: PasteboardChange(
                    typeIdentifiers: ["public.utf8-plain-text"],
                    sourceBundleID: "com.1password.1password",
                    fingerprint: "password"
                ),
                settings: PrivacySettings()
            ),
            .skip(.excludedSource)
        )
    }

    func testRejectsWhenRecordingIsPaused() {
        XCTAssertFalse(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text"], fingerprint: "paused"),
            settings: PrivacySettings(isPaused: true)
        ))
        XCTAssertEqual(
            PrivacyFilter.decide(
                change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text"], fingerprint: "paused"),
                settings: PrivacySettings(isPaused: true)
            ),
            .skip(.paused)
        )
    }

    func testAcceptsPreviouslySeenFingerprintAsANewClipboardEvent() {
        XCTAssertTrue(PrivacyFilter.shouldRecord(
            change: PasteboardChange(
                typeIdentifiers: ["public.utf8-plain-text"],
                sourceBundleID: "com.example.editor",
                fingerprint: "already-seen"
            ),
            settings: PrivacySettings(seenFingerprints: ["already-seen"])
        ))
    }

    func testAcceptsAVisibleNewChangeFromAnAllowedApp() {
        XCTAssertTrue(PrivacyFilter.shouldRecord(
            change: PasteboardChange(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.example.editor", fingerprint: "new"),
            settings: PrivacySettings()
        ))
    }

    func testClipboardItemKindUsesStableStringEncoding() throws {
        let encoded = try JSONEncoder().encode(ClipboardItem.Kind.richText)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"richText\"")
        XCTAssertEqual(try JSONDecoder().decode(ClipboardItem.Kind.self, from: encoded), .richText)
    }
}
