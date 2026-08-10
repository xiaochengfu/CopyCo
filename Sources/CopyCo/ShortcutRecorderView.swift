import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var configuration: HotKeyConfiguration
    let copy: CopyCoCopy
    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        HStack {
            Text(copy.shortcutTitle)
            Spacer()
            Button(model.isRecording ? copy.pressKeys : configuration.displayName) {
                model.start()
            }
            .buttonStyle(.bordered)
            if model.isRecording {
                Button(copy.cancel) { model.stop() }
                    .buttonStyle(.borderless)
            }
        }
        .onAppear {
            model.onCapture = { newConfiguration in
                configuration = newConfiguration
            }
        }
        .onDisappear { model.stop() }
    }
}
