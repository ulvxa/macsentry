import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text("MacSentry needs to see your whole disk to find what is taking space. It never deletes anything on its own.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open Privacy Settings and find Full Disk Access.")
                step(2, "Drag MacSentry into the list, or press + and pick MacSentry. Turn it on.")
                step(3, "Relaunch MacSentry so the permission takes effect.")
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Open Privacy Settings") { model.permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Relaunch MacSentry") { AppRelauncher.relaunch() }
                        .buttonStyle(.glass)
                }
            }

            Button("Continue with limited scan") { model.continueWithLimitedScan() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 520)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LimitedModeBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.isOnboardingPresented = true
        } label: {
            Label("Limited scan", systemImage: "exclamationmark.shield")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
        }
        .help("Full Disk Access is off, so protected folders are skipped. Click to set it up.")
        .accessibilityLabel("Limited scan mode, Full Disk Access is off")
    }
}

struct OnboardingPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.isOnboardingPresented) {
                OnboardingView()
            }
            .toolbar {
                if model.showsLimitedModeBadge {
                    ToolbarItem(placement: .primaryAction) {
                        LimitedModeBadge()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshPermissions()
                }
            }
            .preferredColorScheme(model.settings.appearance.colorScheme)
    }
}
