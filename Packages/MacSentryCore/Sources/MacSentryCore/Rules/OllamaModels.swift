import Foundation

public struct OllamaModel: Sendable, Equatable {
    public let name: String
    public let tag: String
    public let manifestURL: URL
    public let size: Int64

    public var reference: String {
        "\(name):\(tag)"
    }

    public var cliCommand: String {
        "ollama rm \(ShellQuote.quote(reference))"
    }
}

public enum OllamaModelReader {
    private static let defaultRegistry = "registry.ollama.ai"
    private static let defaultNamespace = "library"

    private struct Manifest: Decodable {
        struct Layer: Decodable {
            let digest: String?
            let size: Int64
        }

        let config: Layer?
        let layers: [Layer]
    }

    public static func models(in modelsDirectory: URL) -> [OllamaModel] {
        let manifests = modelsDirectory.appending(path: "manifests", directoryHint: .isDirectory)
        var models: [OllamaModel] = []
        for registry in children(of: manifests) {
            for namespace in children(of: registry) {
                for model in children(of: namespace) {
                    for tag in files(in: model) {
                        guard let size = layerSize(of: tag) else { continue }
                        let name = displayName(
                            registry: registry.lastPathComponent,
                            namespace: namespace.lastPathComponent,
                            model: model.lastPathComponent,
                        )
                        models.append(OllamaModel(name: name, tag: tag.lastPathComponent, manifestURL: tag, size: size))
                    }
                }
            }
        }
        return models.sorted { $0.reference < $1.reference }
    }

    private static func displayName(registry: String, namespace: String, model: String) -> String {
        switch (registry, namespace) {
        case (defaultRegistry, defaultNamespace): model
        case (defaultRegistry, _): "\(namespace)/\(model)"
        default: "\(registry)/\(namespace)/\(model)"
        }
    }

    private static func layerSize(of manifest: URL) -> Int64? {
        guard let data = try? Data(contentsOf: manifest),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        var seen = Set<String>()
        return ([decoded.config].compactMap(\.self) + decoded.layers)
            .filter { $0.digest.map { seen.insert($0).inserted } ?? true }
            .reduce(0) { $0 + $1.size }
    }

    private static func children(of directory: URL) -> [URL] {
        entries(of: directory).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func files(in directory: URL) -> [URL] {
        entries(of: directory).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func entries(of directory: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
        )
        return (contents ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
