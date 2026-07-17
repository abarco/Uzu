import Foundation

struct SongProject: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var sampleRate: Double
    var tracks: [Track]
}

struct Track: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String          // "Guitar", "Lead vocal", ...
    var fileName: String      // relative to project folder
    var gain: Float           // 0.0–1.0, default 1.0
    var isMuted: Bool
    var startOffset: TimeInterval  // latency-compensated placement
    var duration: TimeInterval
    var createdAt: Date
}
