import Foundation

enum LogSizeScale {
    static let minimum: Int64 = 10_000_000
    static let maximum: Int64 = 50_000_000_000

    static func position(for bytes: Int64) -> Double {
        let clamped = min(max(bytes, minimum), maximum)
        return log(Double(clamped) / Double(minimum)) / log(Double(maximum) / Double(minimum))
    }

    static func bytes(at position: Double) -> Int64 {
        let raw = Double(minimum) * pow(Double(maximum) / Double(minimum), min(max(position, 0), 1))
        let magnitude = pow(10, floor(log10(raw)) - 1)
        return min(max(Int64((raw / magnitude).rounded() * magnitude), minimum), maximum)
    }
}
