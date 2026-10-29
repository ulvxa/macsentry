import QuickLook
import SwiftUI

extension View {
    func quickLookPreview(url: Binding<URL?>, in urls: [URL]) -> some View {
        quickLookPreview(url, in: urls.isEmpty ? url.wrappedValue.map { [$0] } ?? [] : urls)
    }
}

struct ScreenActions {
    var canQuarantine: Bool
    var quarantine: @MainActor () -> Void
    var quickLook: (@MainActor () -> Void)?
}

extension FocusedValues {
    @Entry var screenActions: ScreenActions?
}
