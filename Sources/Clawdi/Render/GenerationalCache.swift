/// Two-generation cache used by `PixelCompositor`'s raster caches, bounded by value cost
/// (bytes) rather than entry count, since one frame ranges from ~25 KB at 20 pt to ~2 MB at 400 pt.
///
/// Lookups promote entries from the cold to the hot generation; when an insert would push the
/// hot generation past `hotBudget`, it becomes the new cold generation and the old cold entries
/// are dropped. This bounds the cache at roughly `2 * hotBudget` while keeping the recently
/// used working set resident — unlike a wholesale `removeAll`, which forced the compositor
/// to re-render every cached frame/outline/layer after each overflow.
struct GenerationalCache<Key: Hashable, Value> {
    private var hot: [Key: Value] = [:]
    private var cold: [Key: Value] = [:]
    private var hotCost = 0
    private let hotBudget: Int
    private let cost: (Value) -> Int

    init(hotBudget: Int, cost: @escaping (Value) -> Int) {
        self.hotBudget = hotBudget
        self.cost = cost
    }

    subscript(key: Key) -> Value? {
        mutating get {
            if let value = hot[key] { return value }
            guard let value = cold.removeValue(forKey: key) else { return nil }
            insert(value, forKey: key)
            return value
        }
        set {
            guard let newValue else {
                if let old = hot.removeValue(forKey: key) { hotCost -= cost(old) }
                cold[key] = nil
                return
            }
            insert(newValue, forKey: key)
        }
    }

    mutating func removeAll() {
        hot.removeAll()
        cold.removeAll()
        hotCost = 0
    }

    private mutating func insert(_ value: Value, forKey key: Key) {
        let added = cost(value)
        if let old = hot[key] {
            hotCost -= cost(old)
        } else if hotCost + added > hotBudget, !hot.isEmpty {
            cold = hot
            hot = [:]
            hotCost = 0
        }
        cold[key] = nil
        hot[key] = value
        hotCost += added
    }
}
