/// Two-generation cache used by `PixelCompositor`'s raster caches.
///
/// Lookups promote entries from the cold to the hot generation; when the hot generation
/// exceeds `hotCapacity`, it becomes the new cold generation and the old cold entries are
/// dropped. This bounds the cache at `2 * hotCapacity` entries while keeping the recently
/// used working set resident — unlike a wholesale `removeAll`, which forced the compositor
/// to re-render every cached frame/outline/layer after each overflow.
struct GenerationalCache<Key: Hashable, Value> {
    private var hot: [Key: Value]
    private var cold: [Key: Value] = [:]
    private let hotCapacity: Int

    init(hotCapacity: Int) {
        self.hotCapacity = hotCapacity
        hot = Dictionary(minimumCapacity: hotCapacity)
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
                hot[key] = nil
                cold[key] = nil
                return
            }
            insert(newValue, forKey: key)
        }
    }

    private mutating func insert(_ value: Value, forKey key: Key) {
        if hot.count >= hotCapacity, hot[key] == nil {
            cold = hot
            hot = Dictionary(minimumCapacity: hotCapacity)
        }
        cold[key] = nil
        hot[key] = value
    }
}
