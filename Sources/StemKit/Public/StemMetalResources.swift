#if os(macOS)
import Foundation

/// MLX 0.30.6 discovers loaded frameworks, but cannot take an arbitrary kernel
/// path. Keep the signed resource framework alive after extracting it outside
/// the app. The serial utility queue owns both installation and bundle loading.
final class StemMetalResources: @unchecked Sendable {
    static let shared = StemMetalResources(
        archive: Bundle.main.url(forResource: "KumoneStemResources", withExtension: "zip"),
        directory: ModelStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Metal"),
        version: Bundle.main.object(forInfoDictionaryKey: "KumoneResourceVersion") as? String)

    let archive: URL?
    private let directory: URL
    private let version: String?
    private let queue = DispatchQueue(label: "im.missuo.kumone.stem-resources", qos: .utility)
    private var loadedBundle: Bundle?

    init(archive: URL?, directory: URL, version: String?) {
        self.archive = archive
        self.directory = directory
        self.version = version
    }

    func load() async throws {
        // A bare SwiftPM executable uses the existing colocated kernel path.
        guard let archive else { return }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.loadedBundle != nil {
                        continuation.resume()
                        return
                    }
                    guard let version = self.version else { throw ResourceError.invalidBundle }
                    let destination = self.directory.appendingPathComponent("KumoneStemResources.framework")
                    let cached = Bundle(url: destination)
                    let library = destination.appendingPathComponent("Resources/default.metallib")
                    if cached?.object(forInfoDictionaryKey: "KumoneResourceVersion") as? String != version
                        || !FileManager.default.fileExists(atPath: library.path) {
                        let staged = self.directory.appendingPathComponent("\(UUID().uuidString).partial")
                        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: staged) }
                        let unpack = Process()
                        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        unpack.arguments = ["-x", "-k", archive.path, staged.path]
                        try unpack.run()
                        unpack.waitUntilExit()
                        guard unpack.terminationStatus == 0 else {
                            throw ResourceError.extractionFailed(unpack.terminationStatus)
                        }
                        let framework = staged.appendingPathComponent("KumoneStemResources.framework")
                        guard let bundle = Bundle(url: framework),
                              bundle.bundleIdentifier == "mlx-swift_Cmlx",
                              bundle.object(forInfoDictionaryKey: "KumoneResourceVersion") as? String == version
                        else { throw ResourceError.invalidBundle }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: framework)
                        } else {
                            try FileManager.default.moveItem(at: framework, to: destination)
                        }
                    }
                    guard let bundle = Bundle(url: destination) else { throw ResourceError.invalidBundle }
                    try bundle.loadAndReturnError()
                    self.loadedBundle = bundle
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
    }

    enum ResourceError: Error {
        case invalidBundle
        case extractionFailed(Int32)
    }
}
#endif
