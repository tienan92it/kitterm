import Foundation

enum Stats {
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(1, max(0, p))
        let idx = clamped * Double(sorted.count - 1)
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        if lo == hi { return sorted[lo] }
        let w = idx - Double(lo)
        return sorted[lo] * (1 - w) + sorted[hi] * w
    }

    static func summaryMs(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return "n=0" }
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let p99 = percentile(sorted, 0.99)
        let minV = sorted.first!
        let maxV = sorted.last!
        return String(
            format: "n=%d min=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f ms",
            sorted.count, minV, p50, p95, p99, maxV
        )
    }
}
