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

        // Playback as fileproviderd asks for it (logged live): each read starts 64 KB before the end of the last range.
        var last = try await read(4 * mb - 64 * 1024).1
        var fromReadAhead = 0
        for _ in 0..<8 {
            await settle()
            let prefetched = await server.downloads.last!
            let count = await server.downloads.count
            last = try await read(last.upperBound - 64 * 1024).1
            if last == prefetched { fromReadAhead += 1 } else { check(await server.downloads.count == count + 2, "a miss downloads directly") }
        }
        check(fromReadAhead >= 7, "sequential reads are answered from the read-ahead (\(fromReadAhead) of 8)")
        check(last.count == Int(PartialReadAhead.maximumUnit), "ranges grow up to the maximum unit")
        await settle()
        let ahead = await server.downloads.last!
        check(ahead.lowerBound < last.upperBound - 64 * 1024 && ahead.count == Int(PartialReadAhead.maximumUnit),
              "the read-ahead overlaps the end of the last range and stays at the maximum")
        // Seen live: the system sometimes asks again from 1.5 MB before the end. The read-ahead is used
        // and only the missing bytes in front of it are fetched.
        let early = last.upperBound - 1536 * 1024
        let before = await server.downloads.count
        last = try await read(early).1
        await settle()
        let fetched = await server.downloads.suffix(from: before)
        check(last.lowerBound == early && last.upperBound == ahead.upperBound, "an early read is answered from the read-ahead")
        check(fetched.first == early..<ahead.lowerBound, "only the bytes before the read-ahead are fetched extra")
        check(fetched.count == 2, "then the next read-ahead starts")
        var position = last.upperBound

        // Skipping a little (interleaved audio) still counts as sequential.
        let gap = try await read(position + 1 * mb)
        check(gap.1.count > Int(4 * mb), "a short gap keeps the larger range")
        position = gap.1.upperBound
        await settle()

        // A seek drops the read-ahead and starts small again.
        let beforeSeek = await server.downloads.count
        let seek = try await read(1000 * mb)
        await settle()
        check(seek.1 == (1000 * mb)..<(1004 * mb), "a seek fetches the base unit")
        check(await server.downloads.count == beforeSeek + 1, "a seek does not read ahead")

        // A failed read-ahead falls back to a direct download.
        let failing = (1011 * mb)..<(1027 * mb) // read-ahead after 1004..1012 starts 1 MB early
        await server.fail(failing)
        _ = try await read(1004 * mb)
        await settle()
        check(await server.downloads.last == failing, "the read-ahead was requested")
        let recovered = try await read(1012 * mb - 64 * 1024)
        check(recovered.1.lowerBound == 1012 * mb - 64 * 1024 && recovered.1.count > Int(4 * mb), "a failed read-ahead is fetched again directly")

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
