/*
 * Copyright (C) 2025 OpenCloud GmbH
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
import CryptoKit
import OSLog

/// WebDAV client for communicating with OpenCloud server
actor WebDAVClient {
    
    private let logger = Logger(subsystem: "eu.opencloud.desktop.FileProviderExt", category: "WebDAVClient")
    
    /// Server base URL (e.g., "https://cloud.example.com")
    let serverURL: URL
    
    /// WebDAV endpoint path (typically "/remote.php/webdav")
    let davPath: String
    
    /// Username for authentication
    private let username: String
    
    /// Password/token for authentication
    private let password: String
    
    /// Whether to use Bearer token auth instead of Basic
    private let useBearer: Bool
    
    /// URL session for network requests
    let session: URLSession

    /// Server TUS capability: nil until loaded, .some(nil) when the server lacks TUS.
    private var tusCapability: TusCapability??
    /// Upload URLs by file fingerprint, so a retried upload resumes instead of restarting.
    private var tusUploads: [String: URL] = [:]
    
    /// User agent string
    private let userAgent = "OpenCloud-macOS/FileProviderExt"
    
    /// PROPFIND request body for directory listing
    private static let propfindBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
            <d:prop>
                <d:resourcetype/>
                <d:getcontenttype/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:creationdate/>
                <d:getetag/>
                <oc:id/>
                <oc:fileid/>
                <oc:permissions/>
                <oc:owner-id/>
                <oc:owner-display-name/>
            </d:prop>
        </d:propfind>
        """.data(using: .utf8)!
    
    /// Maximum number of retries for transient failures
    private static let maxRetries = 3

    /// Base delay for exponential backoff (seconds)
    private static let baseRetryDelay: TimeInterval = 1.0

    /// OpenCloud's synthetic Shares jail has ordinary DAV listing support but
    /// no storage recycle bin or independently searchable space index.
    nonisolated static func isVirtualSharesPath(_ path: String) -> Bool {
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let range = normalized.range(of: "/dav/spaces/", options: .backwards) else { return false }
        let space = String(normalized[range.upperBound...])
        let spaceID = space.split(separator: "$", omittingEmptySubsequences: false).last?
            .split(separator: "!", omittingEmptySubsequences: false).first.map(String.init)
        return spaceID == "a0ca6a90-a365-4782-871e-d44447bbc668"
    }

    init(serverURL: URL, davPath: String = "/remote.php/webdav", username: String, password: String, useBearer: Bool = false, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.serverURL = serverURL
        let root = davPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.davPath = root.isEmpty ? "" : "/" + root
        self.username = username
        self.password = password
        self.useBearer = useBearer


        // Configure URL session
        let config = sessionConfiguration ?? URLSessionConfiguration.default
        // timeoutIntervalForRequest is an idle timeout: a stalled transfer fails after
        // 60 s without data. Do not cap total duration, or large files can never finish.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.session = URLSession(configuration: config)
    }

    /// Whether an error is transient and should be retried
    private func isTransientError(_ error: Error) -> Bool {
        if let webdavError = error as? WebDAVError {
            switch webdavError {
            case .networkError:
                return true
            case .serverError:
                return true
            case .httpError(let statusCode, _):
                // Retry on 429 (rate limit) and 5xx (server errors), except 501 (not implemented)
                return statusCode == 429 || (statusCode >= 500 && statusCode != 501)
            default:
                return false
            }
        }
        // Retry on URLError transient failures
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Execute an operation with retry and exponential backoff for transient errors
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < Self.maxRetries && isTransientError(error) {
                    let delay = Self.baseRetryDelay * pow(2.0, Double(attempt))
                    logger.warning("Transient error (attempt \(attempt + 1)/\(Self.maxRetries + 1)): \(error.localizedDescription). Retrying in \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }
        throw lastError!
    }
    
    /// Create full URL for a remote path
    func url(for remotePath: String) -> URL? {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        
        // Join the configured root with exactly one separator. A common
        // advertised DAV root already ends in '/', while callers use '/' for
        // its contents. Prefix matching must also respect component boundaries.
        let path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        let fullPath: String
        if davPath.isEmpty || path == davPath || path.hasPrefix(davPath + "/") {
            fullPath = path
        } else {
            fullPath = davPath + path
        }
        
        components?.path = fullPath
        return components?.url
    }
    
    /// The path inside the space, e.g. "/folder/file.txt", for both stored forms of a remote path:
    /// relative to the space or the full DAV path that listings return.
    func spaceRelativePath(_ remotePath: String) -> String {
        let path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        let root = davPath.hasSuffix("/") ? String(davPath.dropLast()) : davPath
        let inside = !root.isEmpty && (path == root || path.hasPrefix(root + "/")) ? String(path.dropFirst(root.count)) : path
        return "/" + inside.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Add authentication and common headers to request
    func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        if useBearer {
            // OAuth Bearer token
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        } else {
            // Basic auth
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64 = credentialsData.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }
        
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        return request
    }
    
    private static func quotedETag(_ etag: String) -> String {
        etag.hasPrefix("\"") || etag.hasPrefix("W/\"") ? etag : "\"\(etag)\""
    }

    func isRootPath(_ path: String) -> Bool {
        let separators = CharacterSet(charactersIn: "/")
        return path.trimmingCharacters(in: separators) == url(for: "/")?.path.trimmingCharacters(in: separators)
    }

    // MARK: - Public API
    
    /// List directory contents via PROPFIND Depth: 1
    /// Returns the directory itself as the first item, followed by its children.
    func listDirectory(path: String) async throws -> [WebDAVItem] {
        try await withRetry {
            try await self.performListDirectory(path: path)
        }
    }

    /// ETag of a single resource via PROPFIND Depth: 0. OpenCloud propagates
    /// changes up to the space root, so the root ETag is a cheap change probe.
    func etag(path: String) async throws -> String {
        try await withRetry {
            guard let item = try await self.performListDirectory(path: path, depth: "0").first else {
                throw WebDAVError.parseError("PROPFIND omitted the requested resource")
            }
            return item.etag
        }
    }

    private func performListDirectory(path: String, depth: String = "1") async throws -> [WebDAVItem] {
        guard let url = url(for: path) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("PROPFIND \(url.absoluteString)")

        var request = authenticatedRequest(url: url, method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        logger.debug("PROPFIND response: \(httpResponse.statusCode)")
        if httpResponse.statusCode != 207 {
            logger.error("PROPFIND failed HTTP \(httpResponse.statusCode, privacy: .public)")
        }

        switch httpResponse.statusCode {
        case 207: // Multi-Status
            let parser = WebDAVXMLParser(baseURL: url)
            guard let items = parser.parse(data: data) else {
                logger.error("PROPFIND invalid multistatus response")
                throw WebDAVError.parseError("Failed to parse PROPFIND response")
            }
            logger.debug("Parsed \(items.count) items from PROPFIND")
            // WebDAV does not prescribe response order. Callers expect the
            // requested resource first, so locate it by its decoded path.
            let requestedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let index = items.firstIndex(where: {
                $0.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == requestedPath
            }) else {
                logger.error("PROPFIND response omitted requested resource")
                throw WebDAVError.parseError("PROPFIND omitted the requested resource")
            }
            var ordered = items
            ordered.insert(ordered.remove(at: index), at: 0)
            return ordered

        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 500...599:
            throw WebDAVError.serverError
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }
    }
    
    /// Download a file to a local URL
    func downloadFile(remotePath: String, to localURL: URL, ifMatchEtag: String? = nil, progress: Progress? = nil) async throws {
        try await withRetry {
            try await self.performDownloadFile(remotePath: remotePath, to: localURL, ifMatchEtag: ifMatchEtag, progress: progress)
        }
    }

    private func performDownloadFile(remotePath: String, to localURL: URL, ifMatchEtag: String?, progress: Progress?) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("GET \(url.absoluteString) -> \(localURL.path)")

        var request = authenticatedRequest(url: url, method: "GET")
        if let etag = ifMatchEtag {
            request.setValue(Self.quotedETag(etag), forHTTPHeaderField: "If-Match")
        }

        progress?.kind = .file
        progress?.fileOperationKind = .downloading
        progress?.fileTotalCount = 1
        progress?.completedUnitCount = 0
        let transfer = TransferProgressDelegate(progress: progress)
        let (tempURL, response) = try await session.download(for: request, delegate: transfer)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }

        logger.debug("GET response: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            // Move downloaded file to destination
            let fm = FileManager.default
            if fm.fileExists(atPath: localURL.path) {
                try fm.removeItem(at: localURL)
            }
            try fm.moveItem(at: tempURL, to: localURL)

            progress?.completedUnitCount = progress?.totalUnitCount ?? 1

        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 412:
            throw WebDAVError.conflict
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Upload a file from a local URL
    /// - Parameter ifMatchEtag: If set, sends If-Match header for conflict detection (412 on mismatch)
    func uploadFile(from localURL: URL, to remotePath: String, ifMatchEtag: String? = nil, ifNoneMatch: Bool = false, progress: Progress? = nil, modificationDate: Date? = nil,
                    resumeStore: TusResumeStore? = nil) async throws -> WebDAVItem? {
        let size = Int64((try localURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        if size >= Self.tusThreshold, let tus = await tusSupport() {
            try await performTusUpload(from: localURL, size: size, to: remotePath, tus: tus, ifMatchEtag: ifMatchEtag,
                                       ifNoneMatch: ifNoneMatch, progress: progress, modificationDate: modificationDate, resumeStore: resumeStore)
        } else {
            try await withRetry {
                try await self.performUploadFile(from: localURL, to: remotePath, ifMatchEtag: ifMatchEtag, ifNoneMatch: ifNoneMatch, progress: progress, modificationDate: modificationDate)
            }
        }
        return try await listDirectory(path: remotePath).first
    }

    // MARK: - Resumable uploads (TUS), mirroring the sync engine's PropagateUploadFileTUS

    struct TusCapability {
        let extensions: Set<String>
        let maxChunkSize: Int64
        let methodOverride: Bool
        let checksumType: String
    }

    /// Files from this size use TUS; smaller ones gain nothing from resuming.
    static let tusThreshold: Int64 = 10 * 1024 * 1024
    /// Bytes per PATCH, held in memory while sent. Small enough to keep concurrent
    /// uploads lean; a lost connection costs at most one chunk.
    static let tusChunkSize: Int64 = 8 * 1024 * 1024
    private static let tusMaxStalledAttempts = 5

    func tusSupport() async -> TusCapability? {
        if let known = tusCapability { return known }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.path = "/ocs/v1.php/cloud/capabilities"
        components?.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components?.url else { return nil }
        var request = authenticatedRequest(url: url, method: "GET")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A failed lookup is not cached: the next large upload asks again.
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = ((root["ocs"] as? [String: Any])?["data"] as? [String: Any])?["capabilities"] as? [String: Any] else {
            logger.warning("Could not load server capabilities; using single-request uploads")
            return nil
        }
        let files = capabilities["files"] as? [String: Any]
        let tus = files?["tus_support"] as? [String: Any]
        let checksums = capabilities["checksums"] as? [String: Any]
        let extensions = Set(((tus?["extension"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let capability: TusCapability?
        if let version = tus?["version"] as? String, !version.isEmpty, extensions.contains("creation") {
            capability = TusCapability(extensions: extensions,
                                       maxChunkSize: (tus?["max_chunk_size"] as? NSNumber)?.int64Value ?? 0,
                                       methodOverride: !((tus?["http_method_override"] as? String) ?? "").isEmpty,
                                       checksumType: ((checksums?["preferredUploadType"] as? String) ?? "SHA1").uppercased())
        } else {
            capability = nil
        }
        tusCapability = .some(capability)
        return capability
    }

    private static func checksum(of url: URL, type: String) throws -> (type: String, value: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func digest<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch type {
        case "SHA256": var h = SHA256(); return ("SHA256", try digest(&h))
        case "MD5": var h = Insecure.MD5(); return ("MD5", try digest(&h))
        default: var h = Insecure.SHA1(); return ("SHA1", try digest(&h))
        }
    }

    private func tusRequest(url: URL, method: String, tus: TusCapability, ifMatchEtag: String?, ifNoneMatch: Bool, modificationDate: Date?) throws -> URLRequest {
        var request = authenticatedRequest(url: url, method: method)
        if method == "PATCH" && tus.methodOverride {
            request.httpMethod = "POST"
            request.setValue("PATCH", forHTTPHeaderField: "X-HTTP-Method-Override")
        }
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        if let date = modificationDate {
            let timestamp = date.timeIntervalSince1970.rounded(.down)
            guard timestamp.isFinite, timestamp > Double(Int64.min), timestamp < Double(Int64.max) else { throw CocoaError(.fileWriteUnknown) }
            request.setValue(String(Int64(timestamp)), forHTTPHeaderField: "X-OC-Mtime")
        }
        if let etag = ifMatchEtag { request.setValue(Self.quotedETag(etag), forHTTPHeaderField: "If-Match") }
        if ifNoneMatch { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private static func tusError(_ status: Int) -> WebDAVError {
        switch status {
        case 401: return .notAuthenticated
        case 403: return .permissionDenied
        case 404: return .fileNotFound
        case 412: return .conflict
        case 500...599 where status != 501 && status != 507: return .serverError
        default: return .httpError(statusCode: status, message: nil)
        }
    }

    private func performTusUpload(from localURL: URL, size: Int64, to remotePath: String, tus: TusCapability,
                                  ifMatchEtag: String?, ifNoneMatch: Bool, progress: Progress?, modificationDate: Date?,
                                  resumeStore: TusResumeStore?) async throws {
        guard let base = url(for: "/") else { throw WebDAVError.invalidURL }
        let checksum = try Self.checksum(of: localURL, type: tus.checksumType)
        let mtime = modificationDate.map { String(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? ""
        let fingerprint = [remotePath, String(size), mtime, checksum.value].joined(separator: "\u{0}")
        // The server resolves the filename metadata inside the space, never as a DAV URL path.
        let path = spaceRelativePath(remotePath)
        let chunkLimit = tus.maxChunkSize > 0 ? min(tus.maxChunkSize, Self.tusChunkSize) : Self.tusChunkSize
        progress?.kind = .file
        progress?.fileOperationKind = .uploading
        progress?.fileTotalCount = 1
        progress?.totalUnitCount = max(1, size)

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        func forget() async {
            tusUploads[fingerprint] = nil
            await resumeStore?.removeTusLocation(fingerprint: fingerprint)
        }
        var location = tusUploads[fingerprint]
        if location == nil, let stored = await resumeStore?.tusLocation(fingerprint: fingerprint),
           stored.host?.lowercased() == base.host?.lowercased() {
            location = stored
        }
        var offset: Int64 = -1   // unknown: ask the server before sending
        var stalled = 0
        while offset < size {
            try Task.checkCancellation()
            do {
                if let current = location, offset < 0 {
                    let request = try tusRequest(url: current, method: "HEAD", tus: tus, ifMatchEtag: nil, ifNoneMatch: false, modificationDate: nil)
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw WebDAVError.networkError(URLError(.badServerResponse)) }
                    if [403, 404, 410].contains(http.statusCode) {
                        // The server discarded the partial upload: start a new one.
                        await forget()
                        location = nil
                        offset = 0
                        continue
                    }
                    guard http.statusCode == 200 || http.statusCode == 204,
                          let value = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init), value <= size else {
                        throw Self.tusError(http.statusCode)
                    }
                    offset = value
                    progress?.completedUnitCount = offset
                    logger.info("Resuming upload at \(offset, privacy: .public) of \(size, privacy: .public) bytes")
                    continue
                }
                if offset < 0 { offset = 0 }
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: Int(min(chunkLimit, size - offset))) ?? Data()
                guard Int64(chunk.count) == min(chunkLimit, size - offset) else { throw CocoaError(.fileReadUnknown) }
                var request: URLRequest
                let creating = location == nil
                if creating {
                    // The creation request goes to the space root, so a conditional header would be
                    // evaluated against the root, which always exists. Like the sync engine, never send
                    // If-None-Match there; check that the target is still free instead.
                    if ifNoneMatch {
                        do {
                            _ = try await performListDirectory(path: remotePath, depth: "0")
                            throw WebDAVError.conflict
                        } catch WebDAVError.fileNotFound {}
                    }
                    request = try tusRequest(url: base, method: "POST", tus: tus, ifMatchEtag: ifMatchEtag, ifNoneMatch: false, modificationDate: modificationDate)
                    func meta(_ key: String, _ value: String) -> String { key + " " + Data(value.utf8).base64EncodedString() }
                    var metadata = [meta("filename", path), meta("checksum", checksum.type + " " + checksum.value)]
                    if !mtime.isEmpty { metadata.append(meta("mtime", mtime)) }
                    request.setValue(metadata.joined(separator: ","), forHTTPHeaderField: "Upload-Metadata")
                    request.setValue(String(size), forHTTPHeaderField: "Upload-Length")
                } else {
                    request = try tusRequest(url: location!, method: "PATCH", tus: tus, ifMatchEtag: ifMatchEtag, ifNoneMatch: false, modificationDate: modificationDate)
                }
                let sendsData = !creating || tus.extensions.contains("creation-with-upload")
                if sendsData {
                    request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
                    request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
                }
                let transfer = TransferProgressDelegate(progress: progress, baseOffset: offset, totalSize: size)
                let (_, response) = try await session.upload(for: request, from: sendsData ? chunk : Data(), delegate: transfer)
                guard let http = response as? HTTPURLResponse else { throw WebDAVError.networkError(URLError(.badServerResponse)) }
                switch http.statusCode {
                case 200, 201, 204:
                    if creating {
                        guard let header = http.value(forHTTPHeaderField: "Location"),
                              let created = URL(string: header, relativeTo: base)?.absoluteURL,
                              created.host?.lowercased() == base.host?.lowercased() else {
                            throw WebDAVError.parseError("Upload did not receive a location")
                        }
                        location = created
                        tusUploads[fingerprint] = created
                        await resumeStore?.saveTusLocation(created, fingerprint: fingerprint)
                    }
                    let reported = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
                    let next = reported ?? (sendsData ? offset + Int64(chunk.count) : offset)
                    guard next >= offset, next <= size else { throw WebDAVError.parseError("Invalid upload offset") }
                    if next > offset {
                        stalled = 0
                    } else if sendsData {
                        stalled += 1
                        guard stalled <= Self.tusMaxStalledAttempts else { throw WebDAVError.parseError("Upload made no progress") }
                    }
                    offset = next
                    progress?.completedUnitCount = offset
                case 409 where !creating:
                    // Offset mismatch on a diverged resume: ask the server where it stands.
                    stalled += 1
                    guard stalled <= Self.tusMaxStalledAttempts else { throw WebDAVError.conflict }
                    offset = -1
                case 460:
                    // Checksum mismatch: the server rejected the assembled file.
                    await forget()
                    throw WebDAVError.httpError(statusCode: 460, message: "Checksum mismatch")
                case 409:
                    throw WebDAVError.conflict
                default:
                    throw Self.tusError(http.statusCode)
                }
            } catch {
                guard isTransientError(error), stalled < Self.tusMaxStalledAttempts else {
                    if !isTransientError(error) && !(error is CancellationError) && (error as? URLError)?.code != .cancelled { await forget() }
                    throw error
                }
                stalled += 1
                let delay = Self.baseRetryDelay * pow(2.0, Double(stalled - 1))
                logger.warning("Upload interrupted (attempt \(stalled, privacy: .public)), resuming in \(delay, privacy: .public)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Ask the server how much arrived instead of resending from the last chunk start.
                if location != nil { offset = -1 }
            }
        }
        await forget()
    }

    private func performUploadFile(from localURL: URL, to remotePath: String, ifMatchEtag: String?, ifNoneMatch: Bool, progress: Progress?, modificationDate: Date?) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("PUT \(localURL.path) -> \(url.absoluteString)")

        var request = authenticatedRequest(url: url, method: "PUT")
        if let date = modificationDate {
            let timestamp = date.timeIntervalSince1970.rounded(.down)
            guard timestamp.isFinite, timestamp > Double(Int64.min), timestamp < Double(Int64.max) else {
                throw CocoaError(.fileWriteUnknown)
            }
            request.setValue(String(Int64(timestamp)), forHTTPHeaderField: "X-OC-Mtime")
        }

        // FileProvider content URLs are temporary files and may have no useful
        // extension. The remote filename determines the uploaded media type.
        if let uti = UTType(filenameExtension: (remotePath as NSString).pathExtension) {
            request.setValue(uti.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        // Conflict detection via ETag
        if let etag = ifMatchEtag {
            // Older cached versions omitted the HTTP entity-tag quotes.
            request.setValue(Self.quotedETag(etag), forHTTPHeaderField: "If-Match")
        }
        if ifNoneMatch {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        // Stream from file instead of loading into memory to avoid OOM on large files
        progress?.kind = .file
        progress?.fileOperationKind = .uploading
        progress?.fileTotalCount = 1
        let size = (try localURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        progress?.totalUnitCount = Int64(max(1, size))
        progress?.completedUnitCount = 0
        let transfer = TransferProgressDelegate(progress: progress)
        let (_, response) = try await session.upload(for: request, fromFile: localURL, delegate: transfer)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }

        logger.debug("PUT response: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200, 201, 204:
            progress?.completedUnitCount = progress?.totalUnitCount ?? 1

            return

        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 409, 412:
            throw WebDAVError.conflict
        case 507:
            throw WebDAVError.httpError(statusCode: 507, message: "Insufficient storage")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Preserve a local edit under a separate name when the original changed
    /// remotely. Every write is create-only; neither remote version is overwritten.
    func uploadConflictCopy(from localURL: URL, directory: String, filename: String, progress: Progress? = nil, modificationDate: Date? = nil,
                            resumeStore: TusResumeStore? = nil) async throws -> WebDAVItem {
        guard let contentHash = SHA256.hash(contentsOf: localURL) else { throw CocoaError(.fileReadUnknown) }
        let digest = contentHash.map { String(format: "%02x", $0) }.joined()
        let pathExtension = (filename as NSString).pathExtension
        let stem = pathExtension.isEmpty ? filename : (filename as NSString).deletingPathExtension
        for attempt in 0..<3 {
            let suffix = attempt == 0 ? String(digest.prefix(12)) : UUID().uuidString.lowercased()
            let marker = " (conflict " + suffix + ")"
            let extensionSuffix = pathExtension.isEmpty ? "" : "." + pathExtension
            let keptExtension = marker.utf8.count + extensionSuffix.utf8.count < 254 ? extensionSuffix : ""
            var keptStem = keptExtension.isEmpty ? filename : stem
            while keptStem.utf8.count + marker.utf8.count + keptExtension.utf8.count > 255 { keptStem.removeLast() }
            let copyName = keptStem + marker + keptExtension
            let path = directory.hasSuffix("/") ? directory + copyName : directory + "/" + copyName
            do {
                guard let item = try await uploadFile(from: localURL, to: path, ifNoneMatch: true, progress: progress, modificationDate: modificationDate,
                                                      resumeStore: resumeStore) else {
                    throw WebDAVError.parseError("Conflict copy metadata missing")
                }
                return item
            } catch WebDAVError.conflict {
                // The same edit may already have been uploaded before its reply
                // was lost. Compare bytes before accepting that existing copy.
                guard let existing = try await listDirectory(path: path).first, !existing.isDirectory else { continue }
                let comparison = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: comparison) }
                try await downloadFile(remotePath: existing.remotePath, to: comparison,
                                       ifMatchEtag: existing.etag.isEmpty ? nil : existing.etag)
                if SHA256.hash(contentsOf: comparison) == contentHash { return existing }
            }
        }
        throw WebDAVError.conflict
    }

    /// Create a directory
    func createDirectory(at remotePath: String) async throws -> WebDAVItem? {
        try await withRetry {
            try await self.performCreateDirectory(at: remotePath)
        }
        return try await listDirectory(path: remotePath).first
    }

    private func performCreateDirectory(at remotePath: String) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("MKCOL \(url.absoluteString)")

        let request = authenticatedRequest(url: url, method: "MKCOL")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }

        logger.debug("MKCOL response: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 201:
            return

        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 405:
            throw WebDAVError.httpError(statusCode: 405, message: "Directory already exists")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Delete a file or directory
    func deleteItem(at remotePath: String, ifMatchEtag: String? = nil) async throws {
        try await withRetry {
            try await self.performDeleteItem(at: remotePath, ifMatchEtag: ifMatchEtag)
        }
    }

    private func performDeleteItem(at remotePath: String, ifMatchEtag: String?) async throws {
        guard let url = url(for: remotePath) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("DELETE \(url.absoluteString)")

        var request = authenticatedRequest(url: url, method: "DELETE")
        if let etag = ifMatchEtag {
            request.setValue(Self.quotedETag(etag), forHTTPHeaderField: "If-Match")
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }

        logger.debug("DELETE response: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 412:
            throw WebDAVError.conflict
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
    
    /// Move/rename a file or directory
    func moveItem(from sourcePath: String, to destinationPath: String, overwrite: Bool = false, expectedIdentifier: String? = nil) async throws -> WebDAVItem? {
        do {
            try await withRetry {
                try await self.performMoveItem(from: sourcePath, to: destinationPath, overwrite: overwrite)
            }
        } catch WebDAVError.fileNotFound {
            // A previous attempt may have committed MOVE before its response or
            // metadata fetch was lost. A name match alone cannot prove this.
            let fallbackIdentifier = WebDAVItem.generateIdentifier(from: url(for: sourcePath)?.path ?? sourcePath)
            guard let expectedIdentifier = expectedIdentifier,
                  expectedIdentifier != fallbackIdentifier else {
                throw WebDAVError.fileNotFound
            }
            guard let destination = try await listDirectory(path: destinationPath).first,
                  destination.ocId == expectedIdentifier else {
                throw WebDAVError.conflict
            }
            return destination
        }

        // Once MOVE succeeds, retry only the read. Reissuing MOVE would target
        // a source path that no longer exists.
        return try await listDirectory(path: destinationPath).first
    }

    private func performMoveItem(from sourcePath: String, to destinationPath: String, overwrite: Bool) async throws {
        guard let sourceURL = url(for: sourcePath),
              let destURL = url(for: destinationPath) else {
            throw WebDAVError.invalidURL
        }

        logger.debug("MOVE \(sourceURL.absoluteString) -> \(destURL.absoluteString)")

        var request = authenticatedRequest(url: sourceURL, method: "MOVE")
        request.setValue(destURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkError(NSError(domain: "WebDAV", code: -1, userInfo: nil))
        }

        logger.debug("MOVE response: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 201, 204:
            return

        case 401:
            throw WebDAVError.notAuthenticated
        case 403:
            throw WebDAVError.permissionDenied
        case 404:
            throw WebDAVError.fileNotFound
        case 412:
            throw WebDAVError.httpError(statusCode: 412, message: "Destination already exists")
        default:
            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
}

import UniformTypeIdentifiers

extension WebDAVClient {
    /// The space-specific REPORT route sets the server's resource scope. The
    /// search pattern contains only the user's filename query.
    func searchFiles(query: String, limit: Int) async throws -> [WebDAVItem] {
        guard let range = davPath.range(of: "/dav/spaces/", options: .backwards) else {
            throw CocoaError(.featureUnsupported)
        }
        let space = String(davPath[range.upperBound...])
        guard !space.isEmpty, !space.contains("/"), !Self.isVirtualSharesPath(davPath) else { throw CocoaError(.featureUnsupported) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.utf8.count <= 4096 else { throw CocoaError(.fileReadTooLarge) }

        func quoted(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        func xml(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.path = davPath
        guard let endpoint = components?.url else { throw WebDAVError.invalidURL }
        let pattern = "name:\"*\(quoted(trimmed))*\""
        var request = authenticatedRequest(url: endpoint, method: "REPORT")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <oc:search-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
        <d:prop><d:displayname/><d:getetag/><d:getcontentlength/><d:getcontenttype/>
        <d:resourcetype/><d:getlastmodified/><d:creationdate/><oc:id/><oc:fileid/>
        <oc:permissions/><oc:owner-id/><oc:owner-display-name/></d:prop>
        <oc:search><oc:pattern>\(xml(pattern))</oc:pattern><oc:limit>\(min(max(limit, 1), 1000))</oc:limit></oc:search>
        </oc:search-files>
        """.utf8)
        return try await withRetry {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw WebDAVError.serverError }
            switch response.statusCode {
            case 207:
                guard let items = WebDAVXMLParser(baseURL: endpoint).parse(data: data) else {
                    throw WebDAVError.parseError("Invalid search response")
                }
                // Never publish another domain's results, even if a server
                // ignores the query scope or returns an overbroad response.
                var seen = Set<String>()
                return Array(items.filter {
                    $0.remotePath.hasPrefix(self.davPath + "/")
                        && !$0.remotePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
                        && seen.insert($0.ocId).inserted
                }.prefix(min(max(limit, 1), 1000)))
            case 401: throw WebDAVError.notAuthenticated
            case 403: throw WebDAVError.permissionDenied
            case 404, 405, 501: throw CocoaError(.featureUnsupported)
            case 500...599: throw WebDAVError.serverError
            default: throw WebDAVError.httpError(statusCode: response.statusCode, message: nil)
            }
        }
    }
}
