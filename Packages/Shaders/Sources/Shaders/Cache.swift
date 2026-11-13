import Foundation

/// Values made once per key, however many threads ask at the same moment: the first makes it,
/// the others wait for it. Holds at most `capacity` values and `budget` of their `cost`, letting
/// go of the oldest first. A key whose making failed keeps its error when `keepsFailures`, so a
/// program that does not build is not translated again for every tile.
final class OnceCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Slot {
        let lock = NSLock()
        var value: Result<Value, Error>?
        var cost = 0
    }

    private let lock = NSLock()
    private var slots: [Key: Slot] = [:]
    private var order: [Key] = []
    private var spent = 0
    private let capacity: Int
    private let budget: Int
    private let cost: (Value) -> Int
    private let keepsFailures: Bool

    init(capacity: Int, budget: Int = .max, keepsFailures: Bool = true, cost: @escaping (Value) -> Int = { _ in 0 }) {
        self.capacity = capacity
        self.budget = budget
        self.keepsFailures = keepsFailures
        self.cost = cost
    }

    func value(_ key: Key, make: () throws -> Value) throws -> Value {
        let slot: Slot = lock.withLock {
            if let slot = slots[key] { return slot }
            let slot = Slot()
            slots[key] = slot
            order.append(key)
            trim(keeping: key)
            return slot
        }
        return try slot.lock.withLock {
            if let value = slot.value { return try value.get() }
            let value = Result { try make() }
            if case .failure = value, !keepsFailures {
                // The next to ask tries again, in a slot of its own.
                lock.withLock {
                    if slots[key] === slot {
                        slots[key] = nil
                        order.removeAll { $0 == key }
                    }
                }
                return try value.get()
            }
            slot.value = value
            if case .success(let made) = value {
                let spending = cost(made)
                lock.withLock {
                    // Counted only while the slot is still held; one let go meanwhile was never counted.
                    guard slots[key] === slot else { return }
                    slot.cost = spending
                    spent += spending
                    trim(keeping: key)
                }
            }
            return try value.get()
        }
    }

    /// Lets go of the oldest until within capacity and budget, never of `key`. Under `lock`.
    private func trim(keeping key: Key) {
        var index = 0
        while (order.count > capacity || spent > budget) && index < order.count {
            let oldest = order[index]
            if oldest == key {
                index += 1
                continue
            }
            order.remove(at: index)
            if let slot = slots.removeValue(forKey: oldest) { spent -= slot.cost }
        }
    }
}
