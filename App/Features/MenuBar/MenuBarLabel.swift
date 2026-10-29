import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let pressure = model.menuBar.pressure
        HStack(spacing: 4) {
            Image(systemName: pressure.isLow ? "internaldrive.fill" : "internaldrive")
            if model.settings.menuBarShowText, let latest = pressure.latest {
                Text(MenuBarFormatting.compactFree(latest.importantFree))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear { registerOpener() }
    }

    private var accessibilityText: String {
        guard let latest = model.menuBar.pressure.latest else { return "MacSentry" }
        return "Free disk space \(MenuBarFormatting.spokenSize(latest.importantFree))"
    }

    private func registerOpener() {
        model.menuBar.windowOpener = { openWindow(id: "main") }
    }
}
