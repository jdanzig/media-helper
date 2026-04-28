import Foundation

/// `@unchecked Sendable` box for ferrying non-Sendable values across
/// concurrency boundaries.
///
/// Useful when crossing into closures that Swift's strict concurrency
/// checker insists are `@Sendable` — e.g. the body of
/// `withCheckedThrowingContinuation` in Swift 6 — but where you know
/// the value isn't actually being touched from multiple actors.
///
/// The "unchecked" part means **you're** the one promising thread
/// safety. Use it only when the captured value really is owned by a
/// single execution context for the duration of the closure.
final class UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
