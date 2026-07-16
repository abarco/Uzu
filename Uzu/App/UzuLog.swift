import os

/// Unified logging, one Logger per category (see CLAUDE.md § Instrumentation).
enum Log {
    static let session = Logger(subsystem: "com.uzu.app", category: "session")
    static let engine = Logger(subsystem: "com.uzu.app", category: "engine")
    static let record = Logger(subsystem: "com.uzu.app", category: "record")
    static let playback = Logger(subsystem: "com.uzu.app", category: "playback")
    static let export = Logger(subsystem: "com.uzu.app", category: "export")
    static let store = Logger(subsystem: "com.uzu.app", category: "store")
    static let ui = Logger(subsystem: "com.uzu.app", category: "ui")
}
