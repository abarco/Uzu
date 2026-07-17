import SwiftUI

struct ProjectView: View {
    @State private var model: ProjectViewModel
    @State private var expandedTrackID: UUID?
    @State private var trackToDelete: Track?
    @State private var trackToRename: Track?
    @State private var trackToTrim: Track?
    @State private var renameText = ""
    @State private var showNamePicker = false
    @State private var showCustomNameEntry = false
    @State private var customName = ""
    @State private var speakerWarningPartName: String?
    @State private var showDiscardConfirmation = false

    init(project: SongProject) {
        _model = State(initialValue: ProjectViewModel(project: project))
    }

    var body: some View {
        Group {
            if model.micPermission == .denied {
                MicPermissionDeniedView(openSettings: model.openSystemSettings)
            } else {
                trackListScreen
            }
        }
        .navigationTitle(model.project?.name ?? "Uzu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isExporting {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.exportSong() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!model.canExport)
                    .accessibilityLabel("Export song")
                }
            }
        }
        .sheet(
            item: Binding(
                get: { model.exportedFile },
                set: { model.exportedFile = $0 }
            )
        ) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
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
            ZStack {
                // The count-in overlay must NOT cover the bottom bar — the
                // Cancel button lives there and has to stay visible.
                listArea
                if model.overdubStage == .countIn {
                    CountInOverlay(remaining: model.countInRemaining)
                }
            }
            recordBar
        }
    }

    @ViewBuilder
    private var listArea: some View {
        VStack(spacing: 0) {
            if let project = model.project, !project.tracks.isEmpty {
                List(project.tracks) { track in
                    TrackRow(
                        track: track,
                        peaks: model.waveforms[track.id],
                        isPlaying: model.playingTrackID == track.id,
                        playbackElapsed: model.playbackElapsed,
                        isExpanded: expandedTrackID == track.id,
                        togglePlay: { Task { await model.togglePlayback(for: track) } },
                        toggleMute: { model.toggleMute(for: track.id) },
                        setGain: { model.setGain($0, for: track.id) },
                        requestTrim: { trackToTrim = track },
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
                    .swipeActions(edge: .leading) {
                        Button {
                            renameText = track.name
                            trackToRename = track
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button {
                            Task { await model.beginReRecord(track: track) }
                        } label: {
                            Label("Re-record", systemImage: "arrow.counterclockwise.circle")
                        }
                        .tint(.orange)
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
                .alert(
                    "Rename part",
                    isPresented: Binding(
                        get: { trackToRename != nil },
                        set: { if !$0 { trackToRename = nil } }
                    ),
                    presenting: trackToRename
                ) { track in
                    TextField("Part name", text: $renameText)
                    Button("Save") {
                        model.renameTrack(track.id, to: renameText)
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(item: $trackToTrim) { track in
                    TrimSheet(track: track) { keepStart, keepEnd in
                        Task { await model.trimTrack(track.id, keepStart: keepStart, keepEnd: keepEnd) }
                    }
                    .presentationDetents([.medium])
                }
                transportBar
            } else {
                emptyState
            }
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
                Label(
                    model.isPlayingMix ? "Stop" : "Play all",
                    systemImage: model.isPlayingMix ? "stop.fill" : "play.fill"
                )
                .font(.headline)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.overdubStage != .idle)
            .accessibilityLabel(model.isPlayingMix ? "Stop mix" : "Play all tracks together")

            Spacer()

            Text("\(Self.timeString(model.isPlayingMix ? model.playbackElapsed : 0)) / \(Self.timeString(model.mixDuration))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var recordBar: some View {
        VStack(spacing: 8) {
            switch model.overdubStage {
            case .idle:
                addPartButton
            case .countIn:
                stopButton(label: "Cancel", icon: "xmark.circle.fill")
            case .recording:
                Text(Self.timeString(model.recordingElapsed))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording time")
                if model.backingMutedForSpeaker {
                    Label("Other parts muted — no headphones", systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                stopButton(label: "Stop", icon: "stop.circle.fill")
            case .review:
                reviewBar
            }
        }
        .padding(.vertical, 12)
        .background(.bar)
        .confirmationDialog("Name this part", isPresented: $showNamePicker, titleVisibility: .visible) {
            ForEach(ProjectViewModel.partPresets, id: \.self) { preset in
                Button(preset) { startPart(named: preset) }
            }
            Button("Other…") {
                customName = ""
                showCustomNameEntry = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this part", isPresented: $showCustomNameEntry) {
            TextField("Part name", text: $customName)
            Button("Record") {
                let name = customName.trimmingCharacters(in: .whitespaces)
                startPart(named: name.isEmpty ? "Part" : name)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "No headphones connected",
            isPresented: Binding(
                get: { speakerWarningPartName != nil },
                set: { if !$0 { speakerWarningPartName = nil } }
            )
        ) {
            Button("Record") {
                if let name = speakerWarningPartName {
                    speakerWarningPartName = nil
                    Task { await model.beginAddPart(named: name) }
                }
            }
            Button("Cancel", role: .cancel) { speakerWarningPartName = nil }
        } message: {
            Text("Your other parts will be muted while you record so the speaker doesn't bleed into the mic. You'll still hear the count-in. Put on headphones to hear your parts while recording.")
        }
        .alert("Discard this take?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                Task { await model.discardTake() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recording will be deleted and nothing will be added to your song.")
        }
    }

    private var addPartButton: some View {
        Button {
            showNamePicker = true
        } label: {
            Label("Add a part", systemImage: "record.circle")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.horizontal)
    }

    private func stopButton(label: String, icon: String) -> some View {
        Button {
            Task { await model.stopTake() }
        } label: {
            Label(label, systemImage: icon)
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .symbolEffect(.pulse, isActive: model.overdubStage == .recording)
        .padding(.horizontal)
    }

    private var reviewBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\"\(model.pendingTake?.name ?? "")\" — \(Self.timeString(model.pendingTake?.duration ?? 0))")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    Task { await model.toggleTakePreview() }
                } label: {
                    Image(systemName: model.isPreviewingTake ? "stop.circle.fill" : "play.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPreviewingTake ? "Stop preview" : "Preview take")

                Button {
                    showDiscardConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .accessibilityLabel("Discard take")
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button {
                    Task { await model.redoTake() }
                } label: {
                    Label("Redo", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    model.keepTake()
                } label: {
                    Label("Keep", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.horizontal)
        }
    }

    private func startPart(named name: String) {
        Task {
            if await model.shouldExplainSpeakerMuting() {
                speakerWarningPartName = name
            } else {
                await model.beginAddPart(named: name)
            }
        }
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrackRow: View {
    let track: Track
    let peaks: [Float]?
    let isPlaying: Bool
    let playbackElapsed: TimeInterval
    let isExpanded: Bool
    let togglePlay: () -> Void
    let toggleMute: () -> Void
    let setGain: (Float) -> Void
    let requestTrim: () -> Void
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
                    Text(durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isPlaying ? .red : .secondary)
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

                // Affordance: this row expands to reveal the volume slider.
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if let peaks, !peaks.isEmpty {
                WaveformView(peaks: peaks, tint: track.isMuted ? .secondary : Color.red)
                    .frame(height: 24)
                    .padding(.leading, 44)
                    .opacity(track.isMuted ? 0.4 : 0.85)
            }

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
                    Button(action: requestTrim) {
                        Label("Trim", systemImage: "scissors")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        if isPlaying {
            return "\(ProjectView.timeString(min(playbackElapsed, track.duration))) / \(ProjectView.timeString(track.duration))"
        }
        return ProjectView.timeString(track.duration)
    }
}

private struct WaveformView: View {
    let peaks: [Float]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let barWidth = size.width / CGFloat(peaks.count)
            let midY = size.height / 2
            for (index, peak) in peaks.enumerated() {
                let barHeight = max(1.5, CGFloat(peak) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * barWidth + barWidth * 0.15,
                    y: midY - barHeight / 2,
                    width: barWidth * 0.7,
                    height: barHeight)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                    with: .color(tint))
            }
        }
    }
}

private struct TrimSheet: View {
    let track: Track
    let onTrim: (TimeInterval, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keepStart: Double = 0
    @State private var keepEnd: Double

    init(track: Track, onTrim: @escaping (TimeInterval, TimeInterval) -> Void) {
        self.track = track
        self.onTrim = onTrim
        _keepEnd = State(initialValue: track.duration)
    }

    private var isValid: Bool {
        keepEnd - keepStart >= 0.2
    }
    private var isChanged: Bool {
        keepStart > 0.01 || keepEnd < track.duration - 0.01
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Start", value: timeString(keepStart))
                    Slider(value: $keepStart, in: 0...track.duration)
                    LabeledContent("End", value: timeString(keepEnd))
                    Slider(value: $keepEnd, in: 0...track.duration)
                } footer: {
                    Text(
                        isValid
                            ? "Keeps \(timeString(keepEnd - keepStart)) of \(timeString(track.duration)). Trimming can't be undone."
                            : "The kept region must be at least 0.2 seconds.")
                }
            }
            .navigationTitle("Trim \"\(track.name)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trim") {
                        onTrim(keepStart, min(keepEnd, track.duration))
                        dismiss()
                    }
                    .disabled(!isValid || !isChanged)
                }
            }
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct CountInOverlay: View {
    let remaining: Int

    var body: some View {
        VStack(spacing: 8) {
            Text("\(remaining)")
                .font(.system(size: 140, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: remaining)
            Text("Get ready…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
        .accessibilityLabel("Count-in: \(remaining)")
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
    NavigationStack {
        ProjectView(
            project: SongProject(id: UUID(), name: "My Song", sampleRate: 48_000, tracks: []))
    }
}
