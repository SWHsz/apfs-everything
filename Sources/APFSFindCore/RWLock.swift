import Darwin

/// A small pthread read/write lock wrapper. Callers keep I/O outside critical sections.
final class RWLock: @unchecked Sendable {
    private var value = pthread_rwlock_t()

    init() {
        precondition(pthread_rwlock_init(&value, nil) == 0, "Unable to initialize index lock")
    }

    deinit { precondition(pthread_rwlock_destroy(&value) == 0) }

    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        precondition(pthread_rwlock_rdlock(&value) == 0)
        defer { precondition(pthread_rwlock_unlock(&value) == 0) }
        return try body()
    }

    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        precondition(pthread_rwlock_wrlock(&value) == 0)
        defer { precondition(pthread_rwlock_unlock(&value) == 0) }
        return try body()
    }
}
