// Copyright © Anthony DePasquale

import Foundation

/// An actor that allows async coordination between concurrent tasks.
///
/// Uses `CheckedContinuation` for efficient wake-up rather than polling.
/// Once signaled, all current and future waiters proceed immediately.
actor AsyncEvent {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var isSignaled: Bool {
        signaled
    }
}

/// An actor that counts calls and exposes the current value.
actor CallCounter {
    private var count = 0

    /// Increments the counter and returns the new value.
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int {
        count
    }
}

/// An actor that tracks the order of events for verification.
actor CallOrderTracker {
    private var order: [String] = []

    func append(_ event: String) {
        order.append(event)
    }

    var events: [String] {
        order
    }
}

/// Polls a condition until it returns `true` or the timeout expires.
///
/// - Parameters:
///   - timeout: Maximum time to wait (default 2 seconds).
///   - interval: Time between polls (default 20ms).
///   - condition: An async closure that returns `true` when the expected state is reached.
/// - Returns: `true` if the condition was met, `false` if the timeout expired.
func pollUntil(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool,
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
