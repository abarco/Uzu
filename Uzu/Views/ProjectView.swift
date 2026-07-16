import SwiftUI

struct ProjectView: View {
    @State private var model = ProjectViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.micPermission == .denied {
                    MicPermissionDeniedView(openSettings: model.openSystemSettings)
                } else {
                    trackListScreen
                }
            }
            .navigationTitle(model.project?.name ?? "Uzu")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await model.onAppear()
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

    private var trackListScreen: some View {
        VStack(spacing: 0) {
            if let project = model.project, !project.tracks.isEmpty {
                List(project.tracks) { track in
                    TrackRow(
                        track: track,
                        isPlaying: model.playingTrackID == track.id,
                        togglePlay: { Task { await model.togglePlayback(for: track) } }
                    )
                }
                .listStyle(.plain)
            } else {
                emptyState
            }
            recordBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Record your first part.")
                .font(.title3.bold())
            Text("Everything you add next will play along with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordBar: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                Text(Self.timeString(model.recordingElapsed))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording time")
            }
            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(
                    model.isRecording ? "Stop" : "Record a part",
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .symbolEffect(.pulse, isActive: model.isRecording)
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(.bar)
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrackRow: View {
    let track: Track
    let isPlaying: Bool
    let togglePlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title)
                    .foregroundStyle(isPlaying ? .red : .accentColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.body.weight(.medium))
                Text(durationString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var durationString: String {
        let total = Int(track.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MicPermissionDeniedView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Uzu needs the microphone")
                .font(.title3.bold())
            Text("Recording your parts requires microphone access. You can turn it on in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ProjectView()
}
