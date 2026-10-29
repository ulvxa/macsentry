import Foundation
import MacSentryCore

enum MenuBarFormatting {
    static func compactFree(_ bytes: Int64, locale: Locale = .current) -> String {
        let value = Double(max(bytes, 0))
        switch value {
        case 1e12...: return "\((value / 1e12).formatted(.number.precision(.fractionLength(1)).locale(locale))) TB"
        case 1e10...: return "\((value / 1e9).formatted(.number.precision(.fractionLength(0)).locale(locale))) GB"
        case 1e9...: return "\((value / 1e9).formatted(.number.precision(.fractionLength(1)).locale(locale))) GB"
        default: return "\((value / 1e6).formatted(.number.precision(.fractionLength(0)).locale(locale))) MB"
        }
    }

    static func percentFree(_ sample: DiskSample) -> Int {
        guard sample.totalBytes > 0 else { return 0 }
        return Int((Double(sample.importantFree) / Double(sample.totalBytes) * 100).rounded())
    }

    static func spokenSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
