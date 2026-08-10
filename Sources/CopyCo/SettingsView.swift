import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showsClearAllConfirmation = false

    var body: some View {
        let copy = CopyCoCopy(language: appState.language)
        Form {
            if SettingsPermissionPresentation.shouldShowWarning(isTrusted: appState.accessibilityTrusted) {
                Section {
                    AccessibilityWarningCard(
                        copy: copy,
                        openSettings: appState.openAccessibilitySettings,
                        refreshStatus: appState.refreshAccessibilityTrust
                    )
                }
            }

            Section(copy.languageSection) {
                Picker(copy.languageLabel, selection: Binding(get: { appState.language }, set: { appState.setLanguage($0) })) {
                    ForEach(CopyCoLanguage.allCases, id: \.self) { option in
                        Text(copy.languageName(option)).tag(option)
                    }
                }
            }
            Section(copy.recordingSection) {
                Toggle(copy.pauseClipboardHistory, isOn: Binding(get: { appState.isPaused }, set: { appState.setPaused($0) }))
                ExcludedApplicationsPicker(appState: appState, copy: copy)
            }
            Section(copy.shortcutSection) {
                ShortcutRecorderView(
                    configuration: Binding(
                        get: { appState.hotKeyConfiguration },
                        set: { appState.updateHotKeyConfiguration($0) }
                    ),
                    copy: copy
                )
                Text(copy.shortcutHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(copy.historyLimitsSection) {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.historyLimit, format: .number)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel(copy.keepItems(appState.historyLimit))
                        Stepper("", value: $appState.historyLimit, in: AppState.historyLimitRange)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                } label: {
                    Text(copy.keepItems(appState.historyLimit))
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.historySizeLimitMB, format: .number)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel(copy.useMegabytes(appState.historySizeLimitMB))
                        Stepper("", value: $appState.historySizeLimitMB, in: AppState.historySizeLimitMBRange)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                } label: {
                    Text(copy.useMegabytes(appState.historySizeLimitMB))
                }
                HStack {
                    Button(copy.applyHistoryLimits, action: appState.applyHistoryLimits)
                    Button(copy.clearAllHistory, role: .destructive) {
                        showsClearAllConfirmation = true
                    }
                }
            }
            Section(copy.storageSection) {
                HStack {
                    Text(appState.historyStoragePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button(copy.revealInFinder, action: appState.revealHistoryStorageInFinder)
                }
            }
            if appState.accessibilityTrusted {
                Section(copy.privacySection) {
                    Label(copy.accessibilityGranted, systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 680)
        .task {
            // Keep the installed-app catalog warm so excluded-application rows
            // resolve real (colored) icons even when the picker popover has
            // never been opened in this session.
            await appState.loadInstalledApplications()
        }
        .confirmationDialog(
            copy.clearAllHistoryConfirmationTitle,
            isPresented: $showsClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(copy.clearAllHistory, role: .destructive, action: appState.clearAll)
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.clearAllHistoryConfirmationMessage)
        }
        .onAppear { appState.refreshAccessibilityTrust() }
    }
}

private struct AccessibilityWarningCard: View {
    let copy: CopyCoCopy
    let openSettings: () -> Void
    let refreshStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.accessibilityWarningTitle)
                        .font(.headline)
                    Text(copy.accessibilityWarningMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(copy.openAccessibilitySettings, action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button(copy.refreshPermissionStatus, action: refreshStatus)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
