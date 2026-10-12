/// Fixed-capacity history that drops its oldest element once full.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Element? { isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Elements from oldest to newest.
    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
