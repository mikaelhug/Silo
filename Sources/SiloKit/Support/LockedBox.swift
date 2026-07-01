import Synchronization

/// A tiny Sendable box for a value written from `@Sendable` callbacks and read afterwards — wraps a
/// `Mutex` in a class so the (noncopyable) lock can be captured by escaping closures.
final class LockedBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func set(_ newValue: Value) { mutex.withLock { $0 = newValue } }
}
