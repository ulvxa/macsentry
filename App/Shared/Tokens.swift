import SwiftUI

// swiftlint:disable identifier_name
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// swiftlint:enable identifier_name

enum Radius {
    static let card: CGFloat = 20
    static let tooltip: CGFloat = 12
    static let inset: CGFloat = 8
}

extension Font {
    static let heroNumber = Font.system(size: 56, weight: .semibold, design: .rounded)
    static let statNumber = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let cardNumber = Font.system(size: 24, weight: .semibold, design: .rounded)
}

extension EnvironmentValues {
    @Entry var homeURL: URL?
}
