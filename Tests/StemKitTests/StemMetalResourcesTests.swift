#if os(macOS)
import Foundation
import MLX
import Testing
@testable import StemKit

@Suite(.serialized)
struct StemMetalResourcesTests {
    @Test func anUnbundledBuildDoesNotInstallResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = StemMetalResources(archive: nil, directory: directory, version: nil)
        try await resources.load()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func invalidArchiveDoesNotBecomeAnInstalledFramework() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("broken.zip")
        try Data("not an archive".utf8).write(to: archive)
        let resources = StemMetalResources(archive: archive, directory: directory, version: "fixture")
        await #expect(throws: StemMetalResources.ResourceError.self) { try await resources.load() }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("KumoneStemResources.framework").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["broken.zip"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KUMONE_STEM_RESOURCE_ARCHIVE"] != nil))
    func compressedResourcesLoadOnceAndSupportMetalComputation() async throws {
        let archive = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KUMONE_STEM_RESOURCE_ARCHIVE"]))
        let version = try #require(ProcessInfo.processInfo.environment["KUMONE_STEM_RESOURCE_VERSION"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = StemMetalResources(archive: archive, directory: directory, version: version)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        async let first: Void = resources.load()
        async let second: Void = resources.load()
        _ = try await (first, second)
        let framework = directory.appendingPathComponent("KumoneStemResources.framework")
        let installed = try framework.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(Bundle.allFrameworks.contains { $0.bundleIdentifier == "mlx-swift_Cmlx" && $0.isLoaded })
        let cached = StemMetalResources(archive: archive, directory: directory, version: version)
        try await cached.load()
        #expect(try framework.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == installed)
        Device.withDefaultDevice(.gpu) {
            let input = MLXArray([Float(1), 2, 3])
            let output = input + input
            eval(output)
            #expect(output.asArray(Float.self) == [2, 4, 6])
        }
    }
}
#endif
