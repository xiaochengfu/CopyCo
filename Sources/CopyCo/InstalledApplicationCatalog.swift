import Foundation

struct InstalledApplication: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let url: URL

    var id: String { bundleIdentifier }
}

protocol InstalledApplicationDiscovering: Sendable {
    func applications() async throws -> [InstalledApplication]
}

struct InstalledApplicationCatalog: InstalledApplicationDiscovering {
    func applications() async throws -> [InstalledApplication] {
        await Task.detached(priority: .utility) {
            Self.normalized(Self.discoverApplications())
        }.value
    }

    static func normalized(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        var applicationsByBundleIdentifier: [String: InstalledApplication] = [:]
        for application in applications where applicationsByBundleIdentifier[application.bundleIdentifier] == nil {
            applicationsByBundleIdentifier[application.bundleIdentifier] = application
        }
        return applicationsByBundleIdentifier.values.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier.localizedStandardCompare(rhs.bundleIdentifier) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    private static func discoverApplications() -> [InstalledApplication] {
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        return directories.flatMap { directory in
            applications(in: directory, fileManager: fileManager)
        }
    }

    private static func applications(in directory: URL, fileManager: FileManager) -> [InstalledApplication] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var applications: [InstalledApplication] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            enumerator.skipDescendants()
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty else {
                continue
            }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            applications.append(
                InstalledApplication(name: name, bundleIdentifier: bundleIdentifier, url: url)
            )
        }
        return applications
    }
}

enum InstalledApplicationSearch {
    static func filter(_ applications: [InstalledApplication], query: String) -> [InstalledApplication] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return applications }
        return applications.filter { application in
            application.name.localizedCaseInsensitiveContains(normalizedQuery)
                || application.bundleIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}
