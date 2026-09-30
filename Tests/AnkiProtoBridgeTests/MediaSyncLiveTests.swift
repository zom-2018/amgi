import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import ImageIO
import Network
import Testing
@testable import AnkiBackend
@testable import AnkiProtoBridge

struct MediaSyncLiveTests {
    @Test(arguments: [SyncDirection.download, .upload])
    func fullSyncFetchesRemoteImageWithoutAKnownMediaVersion(direction: SyncDirection) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try AnkiBackend()
        try backend.openCollection(
            collectionPath: directory.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: directory.appendingPathComponent("media").path,
            mediaDbPath: directory.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }
        let basic = try #require(try await backend.invoke(.notetypeNames).first { $0.name == "Basic" })
        var note = try await backend.invoke(.newNote(notetypeId: basic.id))
        note.fields = ["<img src=\"probe.png\">", "media sync"]
        try await backend.invoke(.addNote(template: note, deckId: DeckID(1)))
        #expect(try await backend.invoke(.checkMedia).missing == ["probe.png"])

        let server = try MediaSyncFixtureServer(direction: direction)
        try await server.start()
        defer { server.stop() }
        try await withDependencies {
            $0.ankiBackend = backend
        } operation: {
            let service = SyncService.liveValue
            try await service.fullSync(server.endpoint, "fixture-key", direction)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while try await service.mediaSyncStatus().active {
                try #require(ContinuousClock.now < deadline, "Media sync did not finish")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let imageURL = directory.appendingPathComponent("media/probe.png")
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(try await backend.invoke(.checkMedia).missing.isEmpty)
        #expect(try await backend.invoke(.checkDatabase).isEmpty)
        if FileManager.default.fileExists(atPath: imageURL.path) {
            let image = try Data(contentsOf: imageURL)
            #expect(try image == fixtureData("probe.png"))
            let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.resourceURL?.appendingPathComponent("MediaSync/\(name)"))
    return try Data(contentsOf: url)
}

/// A loopback-only protocol fixture, not a replacement sync server.
/// Mutable request ordering is confined to the listener's serial queue.
private final class MediaSyncFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "media-sync-fixture")
    private let responses: [(path: String, file: String, originalSize: Int)]
    private var nextResponse = 0

    init(direction: SyncDirection) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        responses = [
            direction == .download
                ? ("/sync/download", "collection.anki2.zst", 147456)
                : ("/sync/upload", "upload.json.zst", 2),
            ("/msync/begin", "begin.json.zst", 47),
            ("/msync/mediaChanges", "changes.json.zst", 79),
            ("/msync/downloadFiles", "media.zip.zst", 373),
            ("/msync/mediaChanges", "empty.json.zst", 21),
            ("/msync/mediaSanity", "sanity.json.zst", 23),
        ]
    }

    var endpoint: String { "http://127.0.0.1:\(listener.port!.rawValue)/" }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            var buffer = buffer
            buffer.append(data ?? Data())
            guard error == nil, !complete, buffer.count < 262144 else {
                connection.cancel()
                return
            }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                receive(connection, buffer: buffer)
                return
            }
            let headers = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
            let bodySize = buffer.count - separator.upperBound
            let length = headers.lowercased().components(separatedBy: "\r\n")
                .first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
            let bodyComplete = length.map { bodySize >= $0 } ?? (buffer.suffix(5) == Data("0\r\n\r\n".utf8))
            guard bodyComplete else {
                receive(connection, buffer: buffer)
                return
            }
            let path = headers.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init)
            guard nextResponse < responses.count, path == responses[nextResponse].path,
                  let body = try? fixtureData(responses[nextResponse].file) else {
                Issue.record("Unexpected media-sync request: \(path ?? headers)")
                connection.cancel()
                return
            }
            let size = responses[nextResponse].originalSize
            nextResponse += 1
            var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nanki-original-size: \(size)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
