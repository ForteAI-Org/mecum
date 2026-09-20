/// UnionFind assigns deterministic component roots using path compression.
struct UnionFind {
    private var parent: [Int] = []

    mutating func makeSet() -> Int {
        let identifier = parent.count
        parent.append(identifier)
        return identifier
    }

    mutating func find(_ identifier: Int) -> Int {
        var root = identifier
        while parent[root] != root { root = parent[root] }
        var current = identifier
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ first: Int, _ second: Int) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        if firstRoot != secondRoot {
            parent[max(firstRoot, secondRoot)] = min(firstRoot, secondRoot)
        }
    }
}
