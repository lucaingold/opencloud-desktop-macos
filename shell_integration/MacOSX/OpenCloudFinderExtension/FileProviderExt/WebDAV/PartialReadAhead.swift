/*
 * Copyright (C) 2026 OpenCloud GmbH
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import Foundation

/// Streaming support for partial downloads. A player reads a video front to back, and each read
/// that misses the local copy costs a round trip through fileproviderd. While reads stay sequential,
/// the fetched ranges grow and the next range is downloaded before it is asked for.
/// A jump elsewhere (seeking) starts again with a small range, so it is answered quickly.
actor PartialReadAhead {
    /// Writes `range` of the item into the file at the same offsets and returns the range delivered.
    typealias Download = @Sendable (_ range: Range<Int64>, _ file: URL) async throws -> Range<Int64>

    static let maximumUnit: Int64 = 64 * 1024 * 1024
    /// Read-ahead nobody asked for within this time is dropped.
    static let idleTimeout: TimeInterval = 60
    static let maximumStreams = 4
    /// fileproviderd often asks for the next range starting a little before the end of the last one
    /// (64 KB to 1.5 MB seen live), so read-ahead starts this much earlier; a larger overlap is
    /// filled with a small extra request. A multiple of any page alignment.
    static let overlap: Int64 = 1024 * 1024

    private struct Prefetch {
        let range: Range<Int64>
        let file: URL
        let task: Task<Range<Int64>, Error>
    }

    private struct Stream {
        let version: String
        /// The last range delivered; the next sequential read starts within it or shortly after.
        var last: Range<Int64>
        var unit: Int64
        var prefetch: Prefetch?
        var lastUse: Date
    }

    private var streams: [String: Stream] = [:]

    /// Delivers a file holding at least `planned` (aligned, starting at or before `requested`).
    /// The returned file belongs to the caller.
    func fetch(item: String, version: String, requested: Range<Int64>, planned: Range<Int64>, fileSize: Int64,
               baseUnit: Int64, directory: URL, now: Date = Date(), download: @escaping Download) async throws -> (file: URL, range: Range<Int64>) {
        dropIdleStreams(now: now)
        var stream = streams[item].flatMap { $0.version == version ? $0 : nil }
        if stream == nil, let stale = streams[item] { discard(stale.prefetch) }

        // Sequential: the read starts within the last range or shortly after it, since players
        // skip small parts (e.g. audio interleaved with video).
        func isSequential(_ stream: Stream?) -> Bool {
            stream.map { $0.last.lowerBound <= planned.lowerBound && planned.lowerBound <= $0.last.upperBound + $0.unit } ?? false
        }

        // Served from the read-ahead; bytes before it that the system asks for again are added to its file.
        if var current = stream, isSequential(current), let prefetch = current.prefetch,
           requested.upperBound <= prefetch.range.upperBound {
            current.prefetch = nil
            current.lastUse = now
            streams[item] = current
            if var delivered = try? await prefetch.task.value {
                var complete = true
                if planned.lowerBound < delivered.lowerBound {
                    if let head = try? await download(planned.lowerBound..<delivered.lowerBound, prefetch.file) {
                        delivered = min(head.lowerBound, delivered.lowerBound)..<delivered.upperBound
                    } else {
                        complete = false
                    }
                }
                if complete {
                    advance(item: item, version: version, delivered: delivered, sequential: true, fileSize: fileSize, baseUnit: baseUnit, directory: directory, download: download)
                    return (prefetch.file, delivered)
                }
            }
            try? FileManager.default.removeItem(at: prefetch.file)
            stream = streams[item]
        }

        let sequential = isSequential(stream)
        if !sequential, let stale = stream?.prefetch {
            discard(stale)
            streams[item]?.prefetch = nil
        }
        var range = planned
        if sequential, let unit = stream?.unit {
            range = planned.lowerBound..<min(max(planned.upperBound, planned.lowerBound + Self.grown(unit)), fileSize)
        }
        let file = directory.appendingPathComponent(UUID().uuidString)
        do {
            let delivered = try await download(range, file)
            advance(item: item, version: version, delivered: delivered, sequential: sequential, fileSize: fileSize, baseUnit: baseUnit, directory: directory, download: download)
            return (file, delivered)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Cancels all read-ahead, e.g. when the extension is torn down.
    func invalidate() {
        for stream in streams.values { discard(stream.prefetch) }
        streams.removeAll()
    }

    static func grown(_ unit: Int64) -> Int64 { min(unit * 2, maximumUnit) }

    private func advance(item: String, version: String, delivered: Range<Int64>, sequential: Bool, fileSize: Int64,
                         baseUnit: Int64, directory: URL, download: @escaping Download) {
        var stream = streams[item].flatMap { $0.version == version ? $0 : nil }
            ?? Stream(version: version, last: delivered, unit: baseUnit, prefetch: nil, lastUse: Date())
        stream.unit = sequential ? max(Int64(delivered.count), baseUnit) : baseUnit
        stream.last = delivered
        stream.lastUse = Date()
        // Read ahead only once the reader moves on sequentially; a single probe (e.g. the index
        // at the end of a video) does not need the following bytes.
        if sequential, stream.prefetch == nil, delivered.upperBound < fileSize {
            let start = max(delivered.lowerBound, delivered.upperBound - Self.overlap)
            let next = start..<min(start + Self.grown(stream.unit), fileSize)
            let file = directory.appendingPathComponent(UUID().uuidString)
            stream.prefetch = Prefetch(range: next, file: file, task: Task { try await download(next, file) })
        }
        streams[item] = stream
        if streams.count > Self.maximumStreams, let oldest = streams.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            discard(oldest.value.prefetch)
            streams[oldest.key] = nil
        }
    }

    private func dropIdleStreams(now: Date) {
        for (item, stream) in streams where now.timeIntervalSince(stream.lastUse) > Self.idleTimeout {
            discard(stream.prefetch)
            streams[item] = nil
        }
    }

    private func discard(_ prefetch: Prefetch?) {
        guard let prefetch else { return }
        prefetch.task.cancel()
        let file = prefetch.file
        Task { _ = try? await prefetch.task.value; try? FileManager.default.removeItem(at: file) }
    }
}
