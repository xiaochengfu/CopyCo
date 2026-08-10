import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExcludedApplicationsPicker: View {
    @ObservedObject var appState: AppState
    let copy: CopyCoCopy

    @State private var isPresented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var selectedApplications: [ExcludedApplicationDisplay] {
        let applicationsByBundleID = Dictionary(
            uniqueKeysWithValues: appState.installedApplications.map { ($0.bundleIdentifier, $0) }
        )
        return appState.excludedBundleIDs.map { bundleIdentifier in
            if let application = applicationsByBundleID[bundleIdentifier] {
                return ExcludedApplicationDisplay(
                    bundleIdentifier: bundleIdentifier,
                    name: application.name,
                    url: application.url
                )
            }
            // The installed-app catalog may not be loaded yet (it is only
            // fetched when the picker popover opens). Resolve the app directly
            // from its bundle identifier so rows keep their real (colored)
            // icon and display name instead of degrading to the generic one.
            let resolvedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            return ExcludedApplicationDisplay(
                bundleIdentifier: bundleIdentifier,
                name: Self.displayName(for: resolvedURL, fallback: bundleIdentifier),
                url: resolvedURL
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// App display name from the resolved bundle URL, falling back to the
    /// bundle identifier when the application cannot be located.
    static func displayName(for url: URL?, fallback: String) -> String {
        url?.deletingPathExtension().lastPathComponent ?? fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.excludedApplications)
                    Text(copy.excludedApplicationsHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button(copy.chooseApplications) {
                    query = ""
                    isPresented = true
                }
                .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                    applicationPopover
                }
            }

            if selectedApplications.isEmpty {
                Text(copy.noExcludedApplications)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack {
                    Text(copy.selectedApplicationsCount(selectedApplications.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(selectedApplications) { application in
                            selectedApplicationRow(application)
                        }
                    }
                }
                .frame(maxHeight: 142)
            }
        }
        .padding(.vertical, 2)
    }

    private var applicationPopover: some View {
        VStack(spacing: 0) {
            TextField(copy.searchApplications, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(12)

            Divider()

            Group {
                if appState.isLoadingInstalledApplications {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(copy.loadingApplications)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = appState.installedApplicationsError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(copy.retry) {
                            Task { await appState.loadInstalledApplications() }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView(copy.noMatchingApplications, systemImage: "magnifyingglass")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredApplications) { application in
                                applicationChoiceRow(application)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: 330)

            Divider()

            HStack {
                Text(copy.selectedApplicationsCount(appState.excludedBundleIDs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copy.done) {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 360)
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .task {
            await appState.loadInstalledApplications()
        }
    }

    private var filteredApplications: [InstalledApplication] {
        InstalledApplicationSearch.filter(appState.installedApplications, query: query)
    }

    private func applicationChoiceRow(_ application: InstalledApplication) -> some View {
        let isSelected = appState.excludedBundleIDs.contains(application.bundleIdentifier)
        return Button {
            appState.setExcluded(!isSelected, for: application.bundleIdentifier)
        } label: {
            HStack(spacing: 10) {
                ApplicationIcon(url: application.url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(application.name)
                        .lineLimit(1)
                    Text(application.bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func selectedApplicationRow(_ application: ExcludedApplicationDisplay) -> some View {
        HStack(spacing: 9) {
            ApplicationIcon(url: application.url, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(application.name)
                    .lineLimit(1)
                if application.name != application.bundleIdentifier {
                    Text(application.bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                appState.setExcluded(false, for: application.bundleIdentifier)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy.removeApplication)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ExcludedApplicationDisplay: Identifiable {
    let bundleIdentifier: String
    let name: String
    let url: URL?

    var id: String { bundleIdentifier }
}

private struct ApplicationIcon: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
