import Observation
import SwiftUI

@MainActor
@Observable
final class ProjectsListViewModel {
    private(set) var projects: [SongProject] = []
    var errorMessage: String?

    private let store: ProjectStore

    init(store: ProjectStore = .standard()) {
        self.store = store
    }

    func reload() {
        projects = store.loadAllProjects().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func createProject(named name: String) -> SongProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let project = try store.createProject(
                name: trimmed.isEmpty ? "My Song" : trimmed, sampleRate: 0)
            reload()
            return project
        } catch {
            Log.store.error("Failed to create project: \(error)")
            errorMessage = "Couldn't create the song."
            return nil
        }
    }

    func deleteProject(_ project: SongProject) {
        do {
            try store.deleteProject(id: project.id)
        } catch {
            Log.store.error("Failed to delete project: \(error)")
            errorMessage = "Couldn't delete the song."
        }
        reload()
    }
}

struct ProjectsListView: View {
    @State private var model = ProjectsListViewModel()
    @State private var path = NavigationPath()
    @State private var showCreateDialog = false
    @State private var newProjectName = "My Song"
    @State private var projectToDelete: SongProject?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            // Inside the stack (not on it): fires again on every pop-back,
            // so part counts and the project snapshots stay fresh.
            .onAppear { model.reload() }
            .navigationTitle("Uzu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newProjectName = "My Song"
                        showCreateDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New song")
                }
            }
            .navigationDestination(for: SongProject.self) { project in
                ProjectView(project: project)
            }
        }
        .alert("New song", isPresented: $showCreateDialog) {
            TextField("Song name", text: $newProjectName)
            Button("Create") {
                if let project = model.createProject(named: newProjectName) {
                    path.append(project)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete \"\(projectToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            ),
            presenting: projectToDelete
        ) { project in
            Button("Delete", role: .destructive) {
                model.deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("All of this song's parts will be deleted. There's no undo.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var projectList: some View {
        List(model.projects) { project in
            NavigationLink(value: project) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body.weight(.medium))
                    Text("\(project.tracks.count) part\(project.tracks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    projectToDelete = project
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Start your first song.")
                .font(.title3.bold())
            Text("Each song is a stack of parts you record one at a time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                newProjectName = "My Song"
                showCreateDialog = true
            } label: {
                Label("New song", systemImage: "plus")
                    .font(.title3.bold())
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Spacer()
        }
    }
}

#Preview {
    ProjectsListView()
}
