import Carbon.HIToolbox
import Foundation

/// Observes macOS Secure Event Input, which password fields enable so other
/// processes cannot observe keystrokes. Carbon global hot keys are not
/// delivered while it is active; CopyCo must not disable it.
enum SecureEventInput {
    static func isEnabled(
        probe: () -> Bool = { IsSecureEventInputEnabled() }
    ) -> Bool {
        probe()
    }
}

/// Polls Secure Event Input and reports transitions. Used for status messaging
/// and for completing deferred UI work after the user leaves a password field.
final class SecureEventInputMonitor {
    var onChange: ((Bool) -> Void)?

    private let queue: DispatchQueue
    private let pollIntervalNanoseconds: UInt64
    private let probe: () -> Bool
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastEnabled: Bool?
    private var generation = 0

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.copyco.secure-event-input", qos: .utility),
        pollIntervalNanoseconds: UInt64 = 250_000_000,
        probe: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.queue = queue
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.probe = probe
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        generation &+= 1
        let generation = generation
        lastEnabled = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(pollIntervalNanoseconds))
        )
        timer.setEventHandler { [weak self] in
            self?.poll(generation: generation)
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        generation &+= 1
        lastEnabled = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    /// Pure transition helper for tests: returns the new published value when
    /// the probed state differs from the last observed one. The first sample
    /// only publishes when Secure Event Input is already enabled at start.
    static func transition(
        previous: Bool?,
        current: Bool
    ) -> Bool? {
        guard let previous else {
            return current ? true : nil
        }
        guard previous != current else { return nil }
        return current
    }

    private func poll(generation: Int) {
        let enabled = probe()
        lock.lock()
        guard generation == self.generation, timer != nil else {
            lock.unlock()
            return
        }
        let published = Self.transition(previous: lastEnabled, current: enabled)
        if published != nil {
            lastEnabled = enabled
        }
        let callback = onChange
        lock.unlock()
        if let published {
            callback?(published)
        }
    }
}
