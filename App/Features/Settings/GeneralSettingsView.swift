import MacSentryCore
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRoots: Set<URL> = []
    @State private var isImporting = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Scan Roots") {
                List(selection: $selectedRoots) {
                    ForEach(settings.scanRoots, id: \.self) { root in
                        ScanRootRow(path: settings.displayPath(root), exists: Self.exists(root))
                    }
                }
                .frame(minHeight: 110)
                .accessibilityLabel("Scan roots")
                HStack(spacing: 8) {
                    Button("Add Folder…", systemImage: "plus") { isImporting = true }
                    Button("Remove", systemImage: "minus") {
                        settings.removeScanRoots(selectedRoots)
                        selectedRoots = []
                    }
                    .disabled(selectedRoots.isEmpty)
                }
                .buttonStyle(.glass)
            }

            Section("Full Disk Access") {
                LabeledContent("Status") {
                    Label(
                        model.hasFullDiskAccess ? "Granted" : "Not granted",
                        systemImage: model.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield",
                    )
                }
                if !model.hasFullDiskAccess {
                    Text("Without Full Disk Access, scans skip protected folders such as Containers, Mail and Messages.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") { model.permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.glassProminent)
                    Button("Check Again") { model.refreshPermissions() }
                        .buttonStyle(.glass)
                    if !model.hasFullDiskAccess {
                        Button("Relaunch MacSentry") { AppRelauncher.relaunch() }
                            .buttonStyle(.glass)
                    }
                }
            }

            Section("Menu Bar and Login") {
                Toggle("Show in menu bar", isOn: $settings.menuBarEnabled)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                settings.addScanRoots(urls)
            }
        }
        .onAppear { model.refreshPermissions() }
    }

    private static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private struct ScanRootRow: View {
    let path: String
    let exists: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: exists ? "folder" : "exclamationmark.triangle")
                .foregroundStyle(exists ? .secondary : .primary)
            Text(path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if !exists {
                Spacer()
                Text("Not found, skipped at scan time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(exists ? path : "\(path) does not exist and will be skipped")
    }
}
