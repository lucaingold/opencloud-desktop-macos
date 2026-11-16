import Foundation

/// Records the ranges the read-ahead downloads; each download writes a marker file.
actor Server {
    var downloads: [Range<Int64>] = []
    var failing: Range<Int64>?
    func record(_ range: Range<Int64>) throws {
        downloads.append(range)
        if range == failing { failing = nil; throw URLError(.timedOut) }
    }
    func fail(_ range: Range<Int64>) { failing = range }
}

@main struct ReadAheadTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static let mb: Int64 = 1024 * 1024
    static let size: Int64 = 2048 * mb

    static func main() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("readahead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        let download: PartialReadAhead.Download = { range, file in
            try await server.record(range)
            try Data("x".utf8).write(to: file)
            return range
        }
        let readAhead = PartialReadAhead()
        func read(_ start: Int64, item: String = "video", version: String = "v1") async throws -> (URL, Range<Int64>) {
            let planned = start..<min(start + 4 * mb, size)
            let result = try await readAhead.fetch(item: item, version: version, requested: start..<(start + 4096), planned: planned,
                                                   fileSize: size, baseUnit: 4 * mb, directory: directory, download: download)
            check(FileManager.default.fileExists(atPath: result.file.path), "the delivered file exists")
            try FileManager.default.removeItem(at: result.file) // the system takes the file over
            return result
        }
        func settle() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

        // Header, then the index at the end (a seek): both stay small and nothing is read ahead.
        _ = try await read(0)
        _ = try await read(size - 4 * mb)
        await settle()
        check(await server.downloads == [0..<(4 * mb), (size - 4 * mb)..<size], "probes fetch only the base unit and do not read ahead")

        // Playback from the start: the second read is sequential, grows and starts the read-ahead.
        _ = try await read(4 * mb)
        _ = try await read(8 * mb)
        await settle()
        check(await server.downloads.suffix(2) == [(8 * mb)..<(16 * mb), (16 * mb)..<(32 * mb)],
              "a sequential read doubles the range and the next range is prefetched")

        let hit = try await read(16 * mb)
        check(hit.1 == (16 * mb)..<(32 * mb), "the next read is answered from the read-ahead")
        await settle()
        check(await server.downloads.last == (32 * mb)..<(64 * mb), "the read-ahead keeps growing")

        // Growth stops at the maximum unit.
        var position: Int64 = 32 * mb
        for _ in 0..<4 {
            let next = try await read(position)
            position = next.1.upperBound
            await settle()
        }
        check(await server.downloads.last.map { $0.count } == Int(PartialReadAhead.maximumUnit), "ranges are capped at the maximum unit")

        // Skipping a little (interleaved audio) still counts as sequential.
        let gapStart = position + 1 * mb
        let gap = try await read(gapStart)
        check(gap.1.count > Int(4 * mb), "a short gap keeps the larger range")
        position = gap.1.upperBound
        await settle()

        // A seek drops the read-ahead and starts small again.
        let before = await server.downloads.count
        let seek = try await read(1000 * mb)
        await settle()
        check(seek.1 == (1000 * mb)..<(1004 * mb), "a seek fetches the base unit")
        check(await server.downloads.count == before + 1, "a seek does not read ahead")

        // A failed read-ahead falls back to a direct download.
        await server.fail((1012 * mb)..<(1028 * mb))
        _ = try await read(1004 * mb)
        await settle()
        let recovered = try await read(1012 * mb)
        check(recovered.1 == (1012 * mb)..<(1028 * mb), "a failed read-ahead is fetched again directly")
        check(await server.downloads.filter { $0 == (1012 * mb)..<(1028 * mb) }.count == 2, "the failed range was downloaded twice")

        // A new version of the file never uses read-ahead from the old one.
        let count = await server.downloads.count
        let fresh = try await read(1044 * mb, version: "v2")
        check(await server.downloads.count == count + 1 && fresh.1 == (1044 * mb)..<(1048 * mb), "a new version starts over")

        // Unused read-ahead is cleaned up.
        await readAhead.invalidate()
        await settle()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(leftovers.isEmpty, "discarded read-ahead files are removed (\(leftovers.count) left)")
        print("FileProvider read-ahead tests passed")
    }
}
