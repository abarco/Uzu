# Uzu 渦

A multi-track overdub recorder for iOS. Record a part (guitar, vocals, percussion…), hear it in your headphones while you record the next one, and export everything mixed into one song.

Named for Ame-no-Uzume, the Japanese goddess whose music lured out the sun: parts spiral together into one song.

## Stack

- Swift + SwiftUI, AVFoundation only — zero third-party dependencies
- iPhone-first, free-tier sideloading (everything on-device)
- Projects are plain folders on disk: audio files + a `project.json` manifest

## Building

```bash
xcodebuild -scheme Uzu -destination 'platform=iOS Simulator,name=<simulator>' build
xcodebuild -scheme Uzu -destination 'platform=iOS Simulator,name=<simulator>' test
```

See `CLAUDE.md` for the full architecture, build phases, and testing strategy.
