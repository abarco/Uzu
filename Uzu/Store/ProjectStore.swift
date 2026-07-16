import Foundation

/// Persists projects as folders on disk: `<root>/<project-id>/project.json` + audio files.
/// The root directory is injectable so tests can point at a temp directory.
final class ProjectStore: Sendable {
    static let manifestFileName = "project.json"

    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Store rooted in the user's Documents folder (visible in the Files app).
    static func standard() -> ProjectStore {
        ProjectStore(rootDirectory: URL.documentsDirectory.appending(path: "Projects"))
    }

    // MARK: - Paths

    func projectFolder(for projectID: UUID) -> URL {
        rootDirectory.appending(path: projectID.uuidString)
    }

    func audioFileURL(fileName: String, projectID: UUID) -> URL {
        projectFolder(for: projectID).appending(path: fileName)
    }

    // MARK: - CRUD

    func createProject(name: String, sampleRate: Double) throws -> SongProject {
        let project = SongProject(id: UUID(), name: name, sampleRate: sampleRate, tracks: [])
        try save(project)
        Log.store.info("Created project \(project.id, privacy: .public) '\(name, privacy: .public)'")
        return project
    }

    func save(_ project: SongProject) throws {
        let folder = projectFolder(for: project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(project)
        try data.write(to: folder.appending(path: Self.manifestFileName), options: .atomic)
        Log.store.info("Saved project \(project.id, privacy: .public) (\(project.tracks.count) tracks)")
    }

    func loadProject(id: UUID) throws -> SongProject {
        let url = projectFolder(for: id).appending(path: Self.manifestFileName)
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(SongProject.self, from: data)
    }

    /// Loads every project under the root. Folders with an unreadable manifest are
    /// skipped (and logged) rather than failing the whole listing.
    func loadAllProjects() -> [SongProject] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var projects: [SongProject] = []
        for folder in folders {
            let manifest = folder.appending(path: Self.manifestFileName)
            do {
                let data = try Data(contentsOf: manifest)
                projects.append(try Self.decoder().decode(SongProject.self, from: data))
            } catch {
                Log.store.error("Skipping unreadable manifest at \(manifest.path): \(error)")
            }
        }
        return projects
    }

    // MARK: - Codable configuration

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
