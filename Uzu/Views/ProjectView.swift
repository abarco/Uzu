import SwiftUI

struct ProjectView: View {
    @State private var model = ProjectViewModel()
    @State private var expandedTrackID: UUID?
    @State private var trackToDelete: Track?

    var body: some View {
        NavigationStack {
            Group {
                if model.micPermission == .denied {
                    MicPermissionDeniedView(openSettings: model.openSystemSettings)
                } else if model.project == nil {
                    // Visible the moment SwiftUI takes over from the (static,
                    // spinner-less by iOS design) launch screen.
                    LoadingView()
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
                        isExpanded: expandedTrackID == track.id,
                        togglePlay: { Task { await model.togglePlayback(for: track) } },
                        toggleMute: { model.toggleMute(for: track.id) },
                        setGain: { model.setGain($0, for: track.id) },
                        toggleExpanded: {
                            withAnimation(.snappy) {
                                expandedTrackID = expandedTrackID == track.id ? nil : track.id
                            }
                        }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            trackToDelete = track
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .alert(
                    "Delete \"\(trackToDelete?.name ?? "")\"?",
                    isPresented: Binding(
                        get: { trackToDelete != nil },
                        set: { if !$0 { trackToDelete = nil } }
                    ),
                    presenting: trackToDelete
                ) { track in
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteTrack(track) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("This part will be removed from the song. There's no undo.")
                }
                transportBar
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

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.toggleMixPlayback() }
            } label: {
                Image(systemName: model.isPlayingMix ? "stop.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(model.isRecording)
            .accessibilityLabel(model.isPlayingMix ? "Stop mix" : "Play mix")

            Text("\(Self.timeString(model.isPlayingMix ? model.playbackElapsed : 0)) / \(Self.timeString(model.mixDuration))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
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

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrackRow: View {
    let track: Track
    let isPlaying: Bool
    let isExpanded: Bool
    let togglePlay: () -> Void
    let toggleMute: () -> Void
    let setGain: (Float) -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: togglePlay) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.title)
                        .foregroundStyle(isPlaying ? .red : Color.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(track.isMuted ? .secondary : .primary)
                    Text(ProjectView.timeString(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: toggleMute) {
                    Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.body)
                        .foregroundStyle(track.isMuted ? .orange : .secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.isMuted ? "Unmute \(track.name)" : "Mute \(track.name)")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(track.gain) },
                            set: { setGain(Float($0)) }
                        ),
                        in: 0...1
                    )
                    Image(systemName: "speaker.wave.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            ProgressView()
            Text("Loading your song…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
