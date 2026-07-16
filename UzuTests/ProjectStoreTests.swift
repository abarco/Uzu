import Foundation
import Testing

@testable import Uzu

struct ProjectStoreTests {
    /// Each test gets its own temp root so tests can run in parallel.
    private func makeTempStore() throws -> (store: ProjectStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "UzuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootDirectory: root), root)
    }

    @Test func createProjectWritesManifestToDisk() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try store.createProject(name: "My Song", sampleRate: 48_000)

        let manifest = root
            .appending(path: project.id.uuidString)
            .appending(path: ProjectStore.manifestFileName)
        #expect(FileManager.default.fileExists(atPath: manifest.path))

        let reloaded = try store.loadProject(id: project.id)
        #expect(reloaded == project)
    }

    @Test func addTrackAndReloadFromDisk() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try store.createProject(name: "Overdubs", sampleRate: 44_100)
        let track = Track(
            id: UUID(),
            name: "Guitar",
            fileName: "guitar.caf",
            gain: 0.8,
            isMuted: true,
            startOffset: 0.0125,
            duration: 12.5,
            createdAt: Date()
        )
        project.tracks.append(track)
        try store.save(project)

        // A brand-new store instance proves nothing survived only in memory.
        let freshStore = ProjectStore(rootDirectory: root)
        let reloaded = try freshStore.loadProject(id: project.id)

        #expect(reloaded.tracks.count == 1)
        let reloadedTrack = try #require(reloaded.tracks.first)
        #expect(reloadedTrack.id == track.id)
        #expect(reloadedTrack.name == "Guitar")
        #expect(reloadedTrack.fileName == "guitar.caf")
        #expect(reloadedTrack.gain == 0.8)
        #expect(reloadedTrack.isMuted)
        #expect(reloadedTrack.startOffset == 0.0125)
        #expect(reloadedTrack.duration == 12.5)
        // ISO 8601 truncates sub-second precision; second-level fidelity is enough.
        #expect(abs(reloadedTrack.createdAt.timeIntervalSince(track.createdAt)) < 1.0)
    }

    @Test func loadAllProjectsSkipsUnreadableManifests() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let good = try store.createProject(name: "Good", sampleRate: 48_000)

        let brokenFolder = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: brokenFolder.appending(path: ProjectStore.manifestFileName))

        let all = store.loadAllProjects()
        #expect(all.count == 1)
        #expect(all.first?.id == good.id)
    }

    @Test func loadAllProjectsOnMissingRootReturnsEmpty() {
        let store = ProjectStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appending(path: "does-not-exist-\(UUID().uuidString)"))
        #expect(store.loadAllProjects().isEmpty)
    }

    @Test func audioFileURLIsInsideProjectFolder() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let url = store.audioFileURL(fileName: "take.caf", projectID: id)
        #expect(url.path.hasPrefix(store.projectFolder(for: id).path))
        #expect(url.lastPathComponent == "take.caf")
    }
}
