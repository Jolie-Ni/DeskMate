import Dispatch
import Foundation

/// Runs async work from synchronous top-level code and rethrows what it threw.
///
/// `main.swift` cannot be async, so every CLI subcommand has to bridge into
/// concurrency somehow. Written inline that bridge is six lines of semaphore
/// and a captured `var` to smuggle the error back out — which this repo had
/// five copies of, and which Swift 5.10 rejects outright as a mutation of a
/// captured var inside a `@Sendable` closure. Swift 6 lets some of those pass
/// on region analysis, so they compiled locally and broke on CI.
///
/// One implementation, one place to be wrong.
public func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
    let box = ErrorBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch { box.error = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = box.error { throw error }
}

/// The semaphore *is* the synchronization: nothing reads `error` before the
/// task signals, and nothing writes it after. `@unchecked` says that out loud
/// rather than adding a lock around an already-ordered handoff.
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
