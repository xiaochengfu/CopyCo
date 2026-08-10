import Carbon.HIToolbox
import Foundation

enum GlobalHotKeyError: LocalizedError {
    case eventHandlerRegistrationFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .eventHandlerRegistrationFailed(status):
            return "Unable to install global hot-key event handler (OSStatus \(status))."
        case let .registrationFailed(status):
            return "Unable to register global hot key (OSStatus \(status))."
        }
    }
}

/// A Carbon-backed system-wide keyboard shortcut registration.
final class GlobalHotKey {
    private static let identifierLock = NSLock()
    private nonisolated(unsafe) static var nextIdentifierID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredIdentifier: EventHotKeyID?
    private var handler: (() -> Void)?

    deinit {
        unregister()
    }

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installationStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                return hotKey.handle(event: event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installationStatus == noErr else {
            self.handler = nil
            throw GlobalHotKeyError.eventHandlerRegistrationFailed(installationStatus)
        }

        let identifier = Self.nextIdentifier()
        registeredIdentifier = identifier
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            unregister()
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event, let registeredIdentifier else { return OSStatus(eventNotHandledErr) }

        var pressedIdentifier = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedIdentifier
        )
        guard parameterStatus == noErr,
              pressedIdentifier.signature == registeredIdentifier.signature,
              pressedIdentifier.id == registeredIdentifier.id else {
            return OSStatus(eventNotHandledErr)
        }
        handler?()
        return noErr
    }

    private static func nextIdentifier() -> EventHotKeyID {
        identifierLock.lock()
        defer { identifierLock.unlock() }
        let identifier = EventHotKeyID(
            signature: OSType(0x4350_434F), // "CPCO"
            id: nextIdentifierID
        )
        nextIdentifierID &+= 1
        if nextIdentifierID == 0 {
            nextIdentifierID = 1
        }
        return identifier
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        registeredIdentifier = nil
        handler = nil
    }
}
