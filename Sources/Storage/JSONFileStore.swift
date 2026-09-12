import Foundation
import os

/// Generic atomic Codable file IO. Missing or corrupt files are tolerated
/// (read returns nil and logs) — a bad history file must never crash the app.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.cleanora.app", category: "storage")

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func write(_ value: Value) throws {
        let data = try encoder.encode(value)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    public func read() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(Value.self, from: data)
        } catch {
            logger.error("JSONFileStore: unreadable \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
