import CoreGraphics

enum TreemapLayout {
    struct Tile<ID> { let id: ID; let rect: CGRect }

    static func squarify<ID>(_ items: [(id: ID, weight: Double)], in rect: CGRect) -> [Tile<ID>] {
        let positive = items.filter { $0.weight > 0 }
        guard !positive.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let totalWeight = positive.reduce(0) { $0 + $1.weight }
        let totalArea = Double(rect.width) * Double(rect.height)
        let scaled = positive.map { (id: $0.id, area: $0.weight / totalWeight * totalArea) }

        var tiles: [Tile<ID>] = []
        var free = rect
        var row: [(id: ID, area: Double)] = []

        func shortest(_ r: CGRect) -> Double { Double(min(r.width, r.height)) }

        func worst(_ row: [(id: ID, area: Double)], _ side: Double) -> Double {
            guard !row.isEmpty, side > 0 else { return .greatestFiniteMagnitude }
            let s = row.reduce(0) { $0 + $1.area }
            let rmax = row.map(\.area).max() ?? 0
            let rmin = row.map(\.area).min() ?? 0
            guard s > 0, rmin > 0 else { return .greatestFiniteMagnitude }
            let side2 = side * side, s2 = s * s
            return max(side2 * rmax / s2, s2 / (side2 * rmin))
        }

        func place(_ row: [(id: ID, area: Double)]) {
            let s = row.reduce(0) { $0 + $1.area }
            guard s > 0 else { return }
            if free.width >= free.height {
                let colW = CGFloat(s / Double(free.height))
                var y = free.minY
                for it in row {
                    let h = CGFloat(it.area / s) * free.height
                    tiles.append(Tile(id: it.id, rect: CGRect(x: free.minX, y: y, width: colW, height: h)))
                    y += h
                }
                free = CGRect(x: free.minX + colW, y: free.minY, width: free.width - colW, height: free.height)
            } else {
                let rowH = CGFloat(s / Double(free.width))
                var x = free.minX
                for it in row {
                    let w = CGFloat(it.area / s) * free.width
                    tiles.append(Tile(id: it.id, rect: CGRect(x: x, y: free.minY, width: w, height: rowH)))
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + rowH, width: free.width, height: free.height - rowH)
            }
        }

        var i = 0
        while i < scaled.count {
            let candidate = scaled[i]
            let side = shortest(free)
            if row.isEmpty || worst(row, side) >= worst(row + [candidate], side) {
                row.append(candidate); i += 1
            } else {
                place(row); row = []
            }
        }
        if !row.isEmpty { place(row) }
        return tiles
    }
}
