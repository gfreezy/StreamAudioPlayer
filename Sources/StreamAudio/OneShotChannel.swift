// Copyright (C) 2022 Gwendal Roué
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

public final class OneShotChannel<T>: @unchecked Sendable {
    // MARK: - Internal State

    private enum Value {
        case pending
        case success(T)
        case error(Error)
    }

    /// The semaphore value.
    private var value: Value

    /// As many elements as there are suspended tasks waiting for a signal.
    /// We store `Suspension` instances instead of `UnsafeContinuation`, because
    /// we support cancellation by removing `Suspension` instances from
    /// this array.
    private var continuation: CheckedContinuation<Void, Never>? = nil

    /// The lock that protects `value` and `continuation`.
    private let _lock = NSRecursiveLock()

    // MARK: - Creating a Semaphore

    /// Creates a semaphore.
    ///
    /// - parameter value: The starting value for the semaphore. Do not pass a
    ///   value less than zero.
    public init(_ type: T.Type) {
        self.value = .pending
    }

    deinit {
        precondition(
            continuation == nil,
            "OneShotChannel is deallocated while task is suspended waiting for a signal.")
    }

    // MARK: - Locking
    //
    // Swift concurrency is... unfinished. We really need to protect our inner
    // state (`value` and `suspension`) across the calls to
    // `withUnsafeContinuation`. Unfortunately, this method introduces a
    // suspension point. So we need a lock. But the Swift compiler is never out
    // of funny jokes:
    //
    // > Instance method 'lock' is unavailable from asynchronous contexts;
    // > Use async-safe scoped locking instead; this is an error in Swift 6
    //
    // This is very immature, because we don't quite have any other solution.
    // Maybe the authors of Swift concurrency will find it interesting
    // eventually to provide 1. building blocks that 2. solve known problems
    // and 3. back deploy. So far they're busy polishing something else.
    //
    // So let's just hide the lock and mute this stupid warning:
    func lock() { _lock.lock() }
    func unlock() { _lock.unlock() }

    var isFinished: Bool {
        lock()
        defer {
            unlock()
        }
        if case .pending = value {
            return false
        } else {
            return true
        }
    }

    // MARK: - Waiting for the Semaphore

    /// Waits for, or decrements, a semaphore.
    ///
    /// Decrement the counting semaphore. If the resulting value is less than
    /// zero, this function suspends the current task until a signal occurs,
    /// without blocking the underlying thread. Otherwise, no suspension happens.
    public func wait() async throws -> T {
        lock()
        defer {
            unlock()
        }
        switch value {
        case .pending:
            break
        case .error(let error):
            throw error
        case .success(let val):
            return val
        }

        await withCheckedContinuation { continuation in
            // Register the continuation that `signal` will resume.
            //
            // The first suspended task will be the first task resumed by `signal`.
            // This is not intended to be a strong fifo guarantee, but just
            // an attempt at some fairness.
            self.continuation = continuation
            unlock()
        }
        lock()
        switch value {
        case .pending:
            fatalError("value in pending state")
        case .error(let error):
            throw error
        case .success(let val):
            return val
        }
    }

    // MARK: - Signaling the Semaphore

    /// Signals (increments) a semaphore.
    ///
    /// Increment the counting semaphore. If the previous value was less than
    /// zero, this function resumes a task currently suspended in ``wait()``.
    ///
    /// - returns This function returns true if a suspended task is resumed.
    ///   Otherwise, false is returned.
    public func finish(_ value: T) {
        lock()
        defer { unlock() }

        self.value = .success(value)

        guard let continuation else {
            // finished before waitting
            return
        }
        continuation.resume()
        self.continuation = nil
    }

    public func finish(throwing: Error) {
        lock()
        defer { unlock() }

        self.value = .error(throwing)

        guard let continuation else {
            // finished before waitting
            return
        }
        continuation.resume()
        self.continuation = nil
    }
}

extension OneShotChannel<Void> {
    public convenience init() {
        self.init(Void.self)
    }
}
