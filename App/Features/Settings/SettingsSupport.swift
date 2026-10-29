import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsFolderList: View {
    let title: String
    @Binding var roots: [URL]
    let displayPath: (URL) -> String
    @State private var selection: Set<URL> = []
    @State private var isImporting = false

    var body: some View {
        List(selection: $selection) {
            ForEach(roots, id: \.self) { root in
                let exists = Self.exists(root)
                HStack(spacing: 8) {
                    Image(systemName: exists ? "folder" : "exclamationmark.triangle")
                        .foregroundStyle(exists ? .secondary : .primary)
                    Text(displayPath(root))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(exists ? displayPath(root) : "Folder not found. It is skipped at scan time")
            }
        }
        .frame(minHeight: 110)
        .accessibilityLabel(title)
        HStack(spacing: 8) {
            Button("Add Folder…", systemImage: "plus") { isImporting = true }
            Button("Remove", systemImage: "minus") {
                roots.removeAll { selection.contains($0) }
                selection = []
            }
            .disabled(selection.isEmpty)
        }
        .buttonStyle(.glass)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                let existing = Set(roots.map(\.standardizedFileURL))
                roots += urls.map(\.standardizedFileURL).filter { !existing.contains($0) }
            }
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

extension View {
    func refreshOnActivate(_ action: @escaping @MainActor () -> Void) -> some View {
        task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                action()
            }
        }
    }
}
