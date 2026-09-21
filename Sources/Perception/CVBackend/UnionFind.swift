/// Growable union-find (disjoint sets) backing the two-pass connected-component labeling. Flat array,
/// path-compressed `find`; sets are created on demand as the first labeling pass discovers them, so we
/// don't preallocate one slot per pixel.
struct UnionFind {
    private var parent: [Int] = []

    /// Create a new singleton set; returns its id.
    mutating func makeSet() -> Int {
        let id = parent.count
        parent.append(id)
        return id
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cur = x
        while parent[cur] != root {            // path compression
            let next = parent[cur]
            parent[cur] = root
            cur = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }   // attach to the lower id (deterministic)
    }
}
