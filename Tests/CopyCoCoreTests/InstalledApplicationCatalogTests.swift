import XCTest
@testable import CopyCo

final class InstalledApplicationCatalogTests: XCTestCase {
    func testNormalizeDeduplicatesBundleIdentifiersAndSortsNames() {
        let apps = [
            InstalledApplication(
                name: "Bravo",
                bundleIdentifier: "com.example.bravo",
                url: URL(fileURLWithPath: "/Applications/Bravo.app")
            ),
            InstalledApplication(
                name: "Alpha",
                bundleIdentifier: "com.example.alpha",
                url: URL(fileURLWithPath: "/Applications/Alpha.app")
            ),
            InstalledApplication(
                name: "Bravo Duplicate",
                bundleIdentifier: "com.example.bravo",
                url: URL(fileURLWithPath: "/Other/Bravo.app")
            )
        ]

        let result = InstalledApplicationCatalog.normalized(apps)

        XCTAssertEqual(result.map(\.name), ["Alpha", "Bravo"])
        XCTAssertEqual(result.map(\.bundleIdentifier), ["com.example.alpha", "com.example.bravo"])
    }

    func testSearchMatchesNameAndBundleIdentifierCaseInsensitively() {
        let apps = [
            InstalledApplication(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                url: URL(fileURLWithPath: "/Applications/Chrome.app")
            ),
            InstalledApplication(
                name: "钉钉",
                bundleIdentifier: "com.alibaba.DingTalkMac",
                url: URL(fileURLWithPath: "/Applications/DingTalk.app")
            )
        ]

        XCTAssertEqual(
            InstalledApplicationSearch.filter(apps, query: "chrome").map(\.name),
            ["Google Chrome"]
        )
        XCTAssertEqual(
            InstalledApplicationSearch.filter(apps, query: "ALIBABA").map(\.name),
            ["钉钉"]
        )
        XCTAssertEqual(InstalledApplicationSearch.filter(apps, query: "  "), apps)
    }

    func testSelectionStateSurvivesSearchFiltering() {
        let chrome = InstalledApplication(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            url: URL(fileURLWithPath: "/Applications/Chrome.app")
        )
        let dingTalk = InstalledApplication(
            name: "钉钉",
            bundleIdentifier: "com.alibaba.DingTalkMac",
            url: URL(fileURLWithPath: "/Applications/DingTalk.app")
        )
        let selected: Set<String> = [dingTalk.bundleIdentifier]

        let filtered = InstalledApplicationSearch.filter([chrome, dingTalk], query: "chrome")

        XCTAssertEqual(filtered, [chrome])
        XCTAssertTrue(selected.contains(dingTalk.bundleIdentifier))
    }

    func testDisplayNameFallsBackToBundleIdentifierWhenURLIsMissing() {
        XCTAssertEqual(
            ExcludedApplicationsPicker.displayName(for: URL(fileURLWithPath: "/Applications/汽水音乐.app"), fallback: "com.soda.music"),
            "汽水音乐"
        )
        XCTAssertEqual(
            ExcludedApplicationsPicker.displayName(for: nil, fallback: "com.soda.music"),
            "com.soda.music"
        )
    }
}
