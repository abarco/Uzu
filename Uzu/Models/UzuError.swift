import Foundation

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

extension UzuError {
    /// Short, human-readable message shown in the UI banner/alert.
    var userMessage: String {
        switch self {
        case .micPermissionDenied:
            return "Uzu needs the microphone to record."
        case .sessionConfigurationFailed:
            return "Couldn't set up audio. Close other audio apps and try again."
        case .engineStartFailed:
            return "Couldn't start the audio engine. Try again."
        case .recordingWriteFailed:
            return "The recording couldn't be saved."
        case .diskSpaceLow(let bytesFree):
            let free = ByteCountFormatter.string(fromByteCount: bytesFree, countStyle: .file)
            return "Not enough free space to record (\(free) left)."
        case .trackFileMissing:
            return "A track's audio file is missing from this project."
        case .exportFailed:
            return "The song couldn't be exported."
        case .interruptedWhileRecording:
            return "Recording stopped because another app took over audio. Your partial take was kept."
        }
    }

    /// Whether the UI should offer a deep link to the Settings app.
    var suggestsOpeningSettings: Bool {
        if case .micPermissionDenied = self { return true }
        return false
    }
}
