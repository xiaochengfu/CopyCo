import AppKit
import CopyCoCore
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var keyboardRouter: HistoryKeyboardRouter
    let onPaste: (ClipboardItem) -> Void
    let onHeightChange: (Int) -> Void
    let onSearchFocusChange: (Bool) -> Void
    let onScrollRequestHandled: (Int) -> Void

    @FocusState private var searchFocused: Bool
    @State private var previews: [ClipboardItem.ID: HistoryPreview] = [:]

    var body: some View {
        let copy = CopyCoCopy(language: appState.language)
        let searchFocusBinding = $searchFocused
        let panelHeight = HistoryPanelSizing.height(
            itemCount: appState.filteredItems.count,
            rowHeight: 56,
            rowSpacing: 6,
            listVerticalPadding: 4,
            headerHeight: 64,
            footerHeight: 32,
            maxHeight: 420
        )
        let itemCountText = appState.searchText.isEmpty
            ? copy.historyItemCount(appState.items.count)
            : copy.filteredHistoryItemCount(appState.filteredItems.count, total: appState.items.count)

        VStack(spacing: 0) {
            TextField(copy.searchHistory, text: $appState.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if appState.filteredItems.isEmpty {
                // Custom empty state instead of ContentUnavailableView: on macOS
                // the system view embeds its own scroll container, so hovering
                // the panel reveals an overlay scrollbar even with no content.
                VStack(spacing: 10) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(appState.searchText.isEmpty ? copy.noClipboardHistory : copy.noMatchingHistory)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(appState.searchText.isEmpty ? copy.emptyHistoryDescription(hotKey: appState.hotKeyConfiguration.displayName) : copy.tryDifferentSearch)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(appState.filteredItems) { item in
                                HStack(spacing: 4) {
                                    Button {
                                        keyboardRouter.selection = item.id
                                        keyboardRouter.focusTarget = .content
                                    } label: {
                                        HistoryRow(
                                            item: item,
                                            language: appState.language,
                                            preview: previews[item.id],
                                            isSelected: keyboardRouter.selection == item.id,
                                            isFocused: keyboardRouter.selection == item.id && keyboardRouter.focusTarget == .content
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded { onPaste(item) }
                                    )
                                    .frame(maxWidth: .infinity)

                                    if keyboardRouter.selection == item.id || item.isPinned {
                                        if keyboardRouter.selection == item.id {
                                            Button {
                                                keyboardRouter.focusTarget = .delete
                                                keyboardRouter.prepareForDeletion(of: item)
                                                appState.delete(item: item)
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 30, height: 44)
                                            }
                                            .buttonStyle(.plain)
                                            .background(
                                                keyboardRouter.focusTarget == .delete
                                                    ? Color.accentColor.opacity(0.2)
                                                    : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(
                                                        keyboardRouter.focusTarget == .delete ? Color.accentColor : Color.clear,
                                                        lineWidth: 1
                                                    )
                                            )
                                            .help(copy.deleteItem)
                                            .accessibilityLabel(copy.deleteItem)
                                        }

                                        Button {
                                            keyboardRouter.selection = item.id
                                            keyboardRouter.focusTarget = .pin
                                            appState.togglePin(item: item)
                                        } label: {
                                            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(item.isPinned ? .orange : .secondary)
                                                .frame(width: 30, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .background(
                                            keyboardRouter.focusTarget == .pin
                                                ? Color.accentColor.opacity(0.2)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .stroke(
                                                    keyboardRouter.focusTarget == .pin ? Color.accentColor : Color.clear,
                                                    lineWidth: 1
                                                )
                                        )
                                        .help(item.isPinned ? copy.unpinItem : copy.pinItem)
                                        .accessibilityLabel(item.isPinned ? copy.unpinItem : copy.pinItem)
                                    }
                                }
                                .id(item.id)
                                .task(id: item.id) {
                                    guard previews[item.id] == nil else { return }
                                    let preview = await appState.loadPreview(for: item)
                                    guard !Task.isCancelled else { return }
                                    previews[item.id] = preview
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    // .automatic = macOS standard overlay behavior: the
                    // scrollbar appears only when content overflows (on hover
                    // or scroll), never when the list fits the panel.
                    .scrollIndicators(.automatic)
                    .onChange(of: keyboardRouter.scrollRequest) { _, request in
                        handleScrollRequest(request, proxy: proxy)
                    }
                    .onAppear {
                        handleScrollRequest(keyboardRouter.scrollRequest, proxy: proxy)
                    }
                }
            }

            if !appState.filteredItems.isEmpty {
                HStack(spacing: 8) {
                    if let statusMessage = appState.statusMessage {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(copy.keyboardHint)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 12)
                    Text(itemCountText)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
        .frame(width: 600, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: appState.filteredItems.map(\.id)) { _, identifiers in
            let pendingScrollRequest = keyboardRouter.scrollRequest
            keyboardRouter.update(items: appState.filteredItems)
            onHeightChange(identifiers.count)
            // Drop previews for rows that are no longer in the filtered list so
            // the in-memory dictionary cannot grow without bound. The provider
            // cache still serves repeat visits without re-reading the disk.
            let visibleIdentifiers = Set(identifiers)
            if previews.keys.contains(where: { !visibleIdentifiers.contains($0) }) {
                previews = previews.filter { visibleIdentifiers.contains($0.key) }
            }
            if identifiers.isEmpty, let pendingScrollRequest {
                DispatchQueue.main.async {
                    onScrollRequestHandled(pendingScrollRequest.sequence)
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in
            onSearchFocusChange(focused)
        }
        .onChange(of: keyboardRouter.searchFocusRequestSequence) { _, _ in
            DispatchQueue.main.async {
                searchFocusBinding.wrappedValue = true
            }
        }
        .onAppear {
            keyboardRouter.onDelete = { [weak appState] item in appState?.delete(item: item) }
            keyboardRouter.onSelectionNavigation = {
                searchFocusBinding.wrappedValue = false
            }
            keyboardRouter.update(items: appState.filteredItems)
            searchFocused = true
            onSearchFocusChange(true)
            onHeightChange(appState.filteredItems.count)
        }
    }

    private func handleScrollRequest(_ request: HistoryKeyboardRouter.ScrollRequest?, proxy: ScrollViewProxy) {
        guard let request else { return }
        let scroll = {
            switch request.alignment {
            case .top:
                proxy.scrollTo(request.target, anchor: .top)
            case .nearest:
                proxy.scrollTo(request.target)
            }
        }
        if request.animated {
            withAnimation(.easeOut(duration: 0.12), scroll)
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction, scroll)
        }
        DispatchQueue.main.async {
            onScrollRequestHandled(request.sequence)
        }
    }
}

struct HistoryMetadataLabels {
    static func make(sourceName: String?, kind: String) -> [String] {
        var labels: [String] = []
        if let sourceName, !sourceName.isEmpty {
            labels.append(sourceName)
            labels.append("·")
        }
        labels.append(kind)
        return labels
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    let language: CopyCoLanguage
    let preview: HistoryPreview?
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HistoryThumbnail(image: previewImage, symbolName: symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    let kind = CopyCoCopy(language: language).itemKind(item.kind)
                    ForEach(
                        Array(HistoryMetadataLabels.make(sourceName: item.sourceName, kind: kind).enumerated()),
                        id: \.offset
                    ) { _, label in
                        Text(label)
                    }
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }

            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 30)
                    .padding(.leading, 3)
                }
            }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }

    private var displayText: String {
        guard let preview, !preview.text.isEmpty else {
            return CopyCoCopy(language: language).itemKind(item.kind)
        }
        return preview.text
    }

    private var previewImage: NSImage? {
        guard let imageData = preview?.imageData else { return nil }
        return NSImage(data: imageData)
    }

    private var symbolName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .file: "folder"
        case .url: "link"
        case .unknown: "clipboard"
        }
    }
}

struct HistoryThumbnail: View {
    let image: NSImage?
    let symbolName: String

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
        }
    }
}
