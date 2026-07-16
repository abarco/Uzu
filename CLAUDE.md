# CLAUDE.md — Uzu

**Uzu** (渦, "whirlpool/spiral"; from Ame-no-Uzume, the Japanese goddess whose music lured out the sun): parts spiral together into one song.

Multi-track overdub recorder for iOS. The user records individual **parts** (guitar, lead vocal, backup vocal, percussion...), hears previous parts through headphones while recording the next one, and finally exports everything mixed into one song file.

**You are building this incrementally. Never move to the next phase until the current phase's acceptance criteria pass.**

---

## Constraints (do not violate)

- **⛔ INSTALL NOTHING WITHOUT EXPLICIT USER PERMISSION.** This is absolute. No Homebrew packages, no Swift Package dependencies, no CocoaPods, no npm/gems, no Xcode components, no simulators/runtimes, no CLI tools, no `xcodes`/`mise`/version managers — nothing. If you believe something must be installed, STOP, state what it is, why it's needed, and what it changes on the machine, and wait for the user to approve. "It would be convenient" is not a reason.
- **Stack:** Swift + SwiftUI only. No third-party audio frameworks — everything uses AVFoundation (`AVAudioEngine`, `AVAudioSession`, `AVAudioFile`).
- **Targets:** iPhone first; iPad should work but is not a design priority yet. No watchOS for this app.
- **Xcode:** current stable (Xcode 26.x). Unit tests use **Swift Testing** (`import Testing`), not XCTest, except UI tests which use XCUITest.
- **Distribution:** free-tier sideloading. No paid entitlements, no CloudKit, no push. Everything on-device.
- **Persistence:** keep it boring — a `Project` folder on disk containing audio files + a `project.json` manifest. No SwiftData/CoreData unless the JSON approach proves inadequate.
- **Dependencies:** zero Swift Package dependencies unless explicitly approved by the user.

---

## Architecture

```
UI (SwiftUI)
  ProjectView ──> ProjectViewModel (ObservableObject / @Observable)
                        │
                        ▼
              AudioEngineService  ← single owner of AVAudioEngine
                        │
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
   RecorderService  PlaybackGraph   ExportService
   (input tap →     (1 AVAudioPlayerNode  (offline manual
    AVAudioFile)     per track → mixer)    rendering → .m4a)
                        │
                        ▼
              ProjectStore (JSON manifest + files on disk)
```

Key rules:

- **One engine.** `AudioEngineService` is the only object that creates/starts/stops `AVAudioEngine` and configures `AVAudioSession`. Recorder, playback, and export all go through it.
- **All audio work off the main thread**; UI state updates marshalled back via `@MainActor`.
- **Record format:** CAF / Linear PCM, at the session's hardware sample rate (typically 48 kHz). Never resample during recording.
- **Export format:** M4A / AAC 256 kbps via offline manual rendering of the same graph.
- **Every track stores a `startOffset` (seconds).** Overdubbed tracks get latency compensation applied at record-stop time: shift by `session.inputLatency + session.outputLatency`. Keep this logic in one pure function so it's unit-testable.

### Data model

```swift
struct SongProject: Codable {
    var id: UUID
    var name: String
    var sampleRate: Double
    var tracks: [Track]
}

struct Track: Codable, Identifiable {
    var id: UUID
    var name: String          // "Guitar", "Lead vocal", ...
    var fileName: String      // relative to project folder
    var gain: Float           // 0.0–1.0, default 1.0
    var isMuted: Bool
    var startOffset: TimeInterval  // latency-compensated placement
    var duration: TimeInterval
    var createdAt: Date
}
```

---

## Build phases

Work through these strictly in order. Each phase ends with: build passes, tests pass, manual checklist confirmed by the user, then a git commit.

### Phase 0 — Project scaffold
- Create Xcode project (iOS App, SwiftUI lifecycle), bundle id and signing set for free-tier sideload.
- Add `NSMicrophoneUsageDescription` to Info.plist.
- Set up folder structure: `App/`, `Audio/`, `Models/`, `Store/`, `Views/`, `Tests/`.
- Verify `xcodebuild` works from the CLI (see Commands) so you can validate builds yourself without the Xcode GUI.

**Accept when:** project builds from CLI for simulator; empty test target runs green.

### Phase 1 — Record one clip, play it back
- `AVAudioSession` configured `.playAndRecord`, `.defaultToSpeaker` off during recording review.
- Record button → input tap → write CAF to project folder. Stop → row appears in track list. Tap play → hear it.
- Handle mic-permission denial with a friendly explainer screen.

**Accept when:** on a real device, user records 10s of speech and plays it back audibly. Unit tests for `ProjectStore` (create project, add track, reload from disk) pass.

### Phase 2 — Multi-track playback
- One `AVAudioPlayerNode` per track through `mainMixerNode`; all tracks start sample-synchronized (schedule against a shared `AVAudioTime` anchor, not sequential `play()` calls).
- Per-track volume slider + mute. Master play/stop.

**Accept when:** three separately recorded clips play simultaneously and stay in sync for their full duration; muting one silences only that one. Unit tests for sync-anchor math pass.

### Phase 3 — Overdub (the heart of the app)
- "Add a part" starts playback of all existing tracks AND recording at the same time.
- Latency compensation applied to the new track's `startOffset` on stop.
- Count-in: 4 metronome ticks before recording begins (generated tone or bundled click sample), also used on the very first recording so the user sets tempo.
- Headphone detection via `AVAudioSession.currentRoute`; if output is the built-in speaker, show a warning ("Use headphones to avoid re-recording your other parts") but allow proceeding.

**Accept when:** user records guitar, then records a vocal over it wearing headphones, and on playback the two are audibly in time (no perceptible lag). Latency-compensation function covered by unit tests with synthetic latency values.

### Phase 4 — Export the song
- Offline manual rendering of the full mix (respect gain/mute/offsets) to `.m4a`.
- Share sheet (`ShareLink` / `UIActivityViewController`) to save or send the song.

**Accept when:** exported file plays correctly in the Files app / Voice Memos and matches what in-app playback sounds like. Unit test: export a project built from two generated sine-wave fixtures and assert output duration and non-silence.

### Phase 5 — Polish (only after 0–4 are solid)
- Re-record / delete / rename a track (with confirmation on delete).
- Simple trim (start/end) per track.
- Waveform thumbnails (compute peaks from the CAF; no library).
- Multiple projects list screen.

---

## Minimal UI spec — "record your part and keep adding"

The whole app should feel like: **open project → big red button → play your part → it stacks**. One primary screen.

**Project screen (the only screen that matters for MVP):**

1. **Track stack** — vertical list, newest part at the bottom. Each row: part name, duration, mute toggle, volume slider (revealed on tap/expand), small re-record + delete actions behind a swipe or ellipsis. Keep rows visually calm; this is a list of "my parts," not a DAW.
2. **Transport bar** (bottom, always visible): one master **Play/Stop** for the whole mix, elapsed/total time.
3. **The big button:** a single prominent **"⏺ Add a part"** button. Tapping it:
   - asks for the part name via a quick preset picker — `Guitar · Vocals · Backup vocals · Percussion · Other…` — one tap, no typing required (Other allows typing),
   - shows the headphone warning if on speaker,
   - runs the 4-beat count-in with big visual countdown numbers,
   - records while playing everything else, with a clear "recording" state (pulsing red, live timer),
   - on stop, drops the new part at the bottom of the stack and immediately offers **"Keep" / "Redo"** with instant playback — one-tap redo is what makes layering feel low-stakes.
4. **First-run empty state:** friendly copy — "Record your first part. Everything you add next will play along with it." — plus the same big button.
5. **Export:** a share icon in the nav bar. That's it.

Deliberately excluded from MVP: tempo/BPM settings, editing waveforms, effects, panning, punch-in. Do not add them.

---

## Testing strategy — how to validate and not get stuck

### The core problem
Audio I/O can't be meaningfully verified by reading code. You must design for testability and lean on three layers:

### Layer 1 — Unit tests (Swift Testing, run on simulator, fast)
Everything that *can* be pure logic *must* be pure logic, so it's testable without hardware:
- `ProjectStore`: round-trip a project to disk and back.
- Latency compensation: `offset(for:inputLatency:outputLatency:)` with synthetic values.
- Sync-anchor math for sample-synchronized playback starts.
- Mix/export pipeline using **generated fixtures**: write short sine waves at known frequencies/amplitudes to CAF in the test, run the offline render, then assert on the output (duration correct; RMS > threshold proves non-silence; a muted track's frequency absent proves mute works — a simple Goertzel/DFT check on a known frequency is acceptable and dependency-free).

Run with `xcodebuild test` (see Commands) after **every** change to audio or store code.

### Layer 2 — Simulator smoke tests (XCUITest, run headless)
- Launch app, create project, tap through: Add a part → count-in → stop → track row exists → master play toggles state.
- The simulator *does* pass host-Mac microphone input through, so a recording flow test can assert a non-empty audio file was created (assert file size > a floor, and duration ≈ recorded time).
- Keep these few and stable — 3–5 flows max. They exist to catch "the app crashes / the flow broke," not audio quality.

### Layer 3 — Manual device checklist (the user runs this; you cannot)
At the end of each phase, STOP and print a short checklist for the user to run on their iPhone, e.g. for Phase 3:
- [ ] With wired/BT headphones: record guitar, then vocal over it. Playback in time?
- [ ] On speaker: warning appears? Bleed audible on the second track (expected)?
- [ ] Kill app mid-recording, relaunch: project intact, no corrupt track row?
- [ ] Receive a phone call during recording (interruption): app recovers without crash?

Do not proceed past a phase until the user confirms the checklist. If they report a failure, fix it within the current phase.

### Rules to avoid getting stuck
1. **Build from the CLI after every meaningful change.** Never accumulate more than ~15 minutes of un-built work.
2. **If a build or test fails twice in a row on the same error, stop and re-read the actual error output** — do not iterate blind. Paste-and-reason, don't guess-and-retry.
3. **Simulator vs device discipline:** audio *logic* problems get debugged in unit tests; audio *hardware* problems (latency, routes, headphones, interruptions) are device-only — ask the user to test rather than speculating.
4. **SwiftUI/AVFoundation API uncertainty:** these APIs churn. If unsure whether an API exists in this Xcode version, write a 5-line spike in the codebase and compile it before building a feature on top of it.
5. **One engine rule violations cause 90% of AVAudioEngine bugs** (`required condition is false` crashes, silent output). If audio silently fails: check session category/activation, engine started, nodes attached *and* connected, formats consistent — in that order.
6. **Commit at every green phase boundary** with a message like `phase-2: multi-track playback ✅`.
7. **Never mock away the file system** in store tests — use a temp directory. Real bugs live in paths and Codable.
8. **Never install anything to work around a problem.** If a fix seems to require installing a tool or dependency, that's a decision for the user (see Constraints).

---

## Instrumentation & logging

No third-party analytics or crash reporters (zero-dependency rule + privacy). Use Apple's unified logging only.

- **`os.Logger`** with subsystem `com.uzu.app` and categories: `session`, `engine`, `record`, `playback`, `export`, `store`, `ui`.
- Log these lifecycle points (info level unless noted):
  - Session configured/activated: category, sample rate, `inputLatency`, `outputLatency`, current route.
  - Engine start/stop; graph rebuilds.
  - Record start/stop: track id, file name, duration, **applied latency offset** (this number is gold when debugging sync complaints).
  - Route changes: old route → new route, and whether a recording was in progress (warning level if so).
  - Interruptions: began/ended + resume options.
  - Export: begin/end, wall time, output duration, file size. Wrap the offline render in an **`OSSignposter`** interval to measure performance.
  - Store: project save/load, and any manifest↔disk mismatch found on launch (error level).
- Errors always log at `.error` with the underlying `Error` description; never swallow silently.
- **DEBUG-only diagnostics screen** (hidden behind a long-press on the app version in a settings/about view): shows current route, latencies, sample rate, free disk space, and a button to export recent app logs (`OSLogStore`) to a text file. This exists so the user can hand you real data for device-only bugs you cannot reproduce in the simulator — ask for it instead of guessing.
- Reading logs during development: `log stream --predicate 'subsystem == "com.uzu.app"'` while a device/simulator is attached.

---

## Error handling

Define one typed error domain and route every failure through it. No `try!`, no force-unwraps, no `fatalError` anywhere in `Audio/` or `Store/`.

```swift
enum UzuError: Error {
    case micPermissionDenied
    case sessionConfigurationFailed(underlying: Error)
    case engineStartFailed(underlying: Error)
    case recordingWriteFailed(underlying: Error)
    case diskSpaceLow(bytesFree: Int64)
    case trackFileMissing(trackID: UUID)
    case exportFailed(underlying: Error)
    case interruptedWhileRecording
}
```

Every case maps to (a) a short human-readable message and (b) a recovery action in the UI — e.g. `micPermissionDenied` → "Uzu needs the microphone to record" + button deep-linking to Settings. Errors surface as a non-blocking banner/alert; the app never dead-ends.

**Cases that MUST be handled (these are the real-world failure modes for a recorder):**

1. **Interruption during recording** (phone call, Siri, alarm): on `.began`, stop the tap and **finalize the partial file safely** — a valid, playable partial take, never a corrupt file. Offer Keep/Redo on the partial. On `.ended` with `.shouldResume`, reactivate the session.
2. **Route change during recording** (headphones yanked out): stop recording gracefully (same partial-take path), log old→new route, inform the user. Never silently continue recording through a route change — latency values are now wrong.
3. **Disk space**: check free bytes before each recording (~12 MB/min at 48 kHz mono PCM; require a sensible floor, e.g. 200 MB). Below the floor → `diskSpaceLow`, block recording with a clear message. Also handle write errors mid-recording via the same partial-take finalization.
4. **App killed/crashed mid-recording**: the input tap already appends to `AVAudioFile` incrementally, so data up to the kill survives. On every launch, reconcile manifest vs files on disk: orphaned audio files become a recovered "Untitled part" row; manifest entries whose file is missing are flagged in the UI (`trackFileMissing`), not silently dropped.
5. **`AVAudioEngineConfigurationChange` notification**: tear down and rebuild the graph, restore player node schedules if playback was active.
6. **Permission denied**: dedicated explainer state (already Phase 1), never a dead record button.
7. **Export failure**: clean up any partial output file, report `exportFailed`, leave the project untouched.

**Testing the error paths** (extend the strategy above):
- Interruption/route-change handlers: extract decision logic into pure functions taking synthetic notification payloads; unit-test all branches.
- Store reconciliation: unit tests with temp dirs containing orphaned files / missing files; assert recovery behavior.
- Disk-space gate: inject a fake "bytes free" provider; test above/below the floor.
- Write failures: point the recorder at a read-only temp directory and assert the partial-take path produces a valid state, not a crash.
- Manual checklist additions (device): receive a real call mid-recording; unplug headphones mid-recording; both must recover per the rules above.

---

## Commands

```bash
# Build for simulator (validate compilation without Xcode GUI)
xcodebuild -scheme Uzu -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run unit + UI tests
xcodebuild -scheme Uzu -destination 'platform=iOS Simulator,name=iPhone 17' test

# List available simulators if the destination above fails
xcrun simctl list devices available
```

(Adjust simulator name to whatever `simctl` reports on this machine.)

---

## Known gotchas (read before touching audio code)

- **Sample-rate mismatches** between input format and file format crash the tap. Always create the `AVAudioFile` with `inputNode.outputFormat(forBus: 0)`.
- **`AVAudioSession` must be configured and activated before the engine starts**, and reconfigured on route changes (headphones plugged/unplugged) and interruptions (calls, Siri). Subscribe to `AVAudioSession.routeChangeNotification` and `.interruptionNotification` from day one (Phase 1), not as polish.
- **Bluetooth headphones add significant, variable latency.** Latency compensation from session properties gets close but may not be perfect over BT; wired is the gold standard. Don't chase BT-perfect alignment in MVP — note it as a known limitation.
- **`AVAudioPlayerNode.play()` calls in a loop are NOT synchronized.** Compute one shared start `AVAudioTime` slightly in the future and schedule every node against it.
- **Offline rendering requires stopping the realtime engine first** and enabling manual rendering mode; restore the realtime configuration afterward.
- **Files app visibility:** set `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so the user can rescue exports even if the share sheet flow has bugs.
