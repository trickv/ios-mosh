import Foundation

/// A value that is set once and awaited by any number of tasks. The first `complete` wins;
/// later ones are ignored. Used to carry results from NIO's event loop to async code: unlike an
/// `EventLoopPromise` it may be completed from any thread, completed twice, or never awaited.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    init() {}

    /// Returns true if this call set the result.
    @discardableResult
    func complete(_ newResult: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = newResult
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, waiter) in toResume { waiter.resume(with: newResult) }
        return true
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool {
        complete(.success(value))
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        complete(.failure(error))
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    /// The result so far, without waiting.
    var current: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    /// Waits for the result. If the calling task is cancelled first, this call throws
    /// `CancellationError`; the OneShot itself stays open for whoever completes it later.
    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }
}
