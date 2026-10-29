import QuickLook
import SwiftUI

extension View {
    /// `urls` is only built while a preview is open, so screens do not re-read the focus or map every row on each render.
    func quickLookPreview(url: Binding<URL?>, in urls: @autoclosure () -> [URL]) -> some View {
        let items = url.wrappedValue == nil ? [] : urls()
        return quickLookPreview(url, in: items.isEmpty ? url.wrappedValue.map { [$0] } ?? [] : items)
    }

    /// Builds the inspector in its own body, so the focus it reads re-renders only the inspector, not the whole screen.
    func deferredInspector(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        inspector(isPresented: isPresented) {
            DeferredContent(content: content)
        }
    }
}

private struct DeferredContent<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
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
