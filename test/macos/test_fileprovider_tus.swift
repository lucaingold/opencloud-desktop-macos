import CryptoKit
import Foundation

// In-process TUS server: stores uploads, can drop a connection mid-chunk after
// keeping part of the body, like a real server that persisted what arrived.
private final class MockTusProtocol: URLProtocol {
    struct Upload { var data = Data(); var length = 0; var metadata = "" }
    static var tusExtensions: String? = "creation,creation-with-upload,checksum"
    static var uploads: [String: Upload] = [:]
    static var requests: [(method: String, path: String, headers: [String: String], bodySize: Int)] = []
    static var putBodies: [String: Data] = [:]
    /// Drop the connection on this PATCH number after keeping this many bytes of its body.
    static var dropPatch: (number: Int, keep: Int)?
    /// Every PATCH keeps this many bytes and then drops, until cleared.
    static var failPatches: Int?
    static var patchCount = 0
    static var postStatus = 201
    /// Paths that do not exist yet; PROPFIND answers 404 until an upload completes.
    static var missing: Set<String> = []
    static func reset() {
        uploads = [:]; requests = []; putBodies = [:]; dropPatch = nil; failPatches = nil; patchCount = 0; postStatus = 201; missing = []
        tusExtensions = "creation,creation-with-upload,checksum"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(_ status: Int, _ headers: [String: String] = [:], _ data: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let method = request.value(forHTTPHeaderField: "X-HTTP-Method-Override") ?? request.httpMethod ?? "GET"
        let path = request.url!.path
        let payload = body()
        Self.requests.append((method, path, request.allHTTPHeaderFields ?? [:], payload.count))
        if path.hasSuffix("/cloud/capabilities") {
            var files: [String: Any] = [:]
            if let ext = Self.tusExtensions {
                files["tus_support"] = ["version": "1.0.0", "resumable": "1.0.0", "extension": ext, "max_chunk_size": 0, "http_method_override": ""]
            }
            let json: [String: Any] = ["ocs": ["data": ["capabilities": ["files": files, "checksums": ["preferredUploadType": "SHA1"]]]]]
            return respond(200, [:], try! JSONSerialization.data(withJSONObject: json))
        }
        switch method {
        case "PUT":
            Self.putBodies[path] = payload
            respond(201)
        case "POST":
            guard Self.postStatus == 201 else { return respond(Self.postStatus) }
            // Like OpenCloud: conditions on the creation request apply to the space root, which exists.
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" { return respond(412) }
            let id = "/data/upload-\(Self.uploads.count + 1)"
            var upload = Upload()
            upload.length = Int(request.value(forHTTPHeaderField: "Upload-Length") ?? "") ?? -1
            upload.metadata = request.value(forHTTPHeaderField: "Upload-Metadata") ?? ""
            upload.data = payload
            Self.uploads[id] = upload
            if upload.data.count == upload.length { Self.missing = [] }
            respond(201, ["Location": id, "Upload-Offset": String(payload.count)])
        case "HEAD":
            guard let upload = Self.uploads[path] else { return respond(404) }
            respond(200, ["Upload-Offset": String(upload.data.count), "Upload-Length": String(upload.length)])
        case "PATCH":
            Self.patchCount += 1
            guard var upload = Self.uploads[path] else { return respond(404) }
            guard request.value(forHTTPHeaderField: "Upload-Offset") == String(upload.data.count) else { return respond(409) }
            if let keep = Self.failPatches ?? (Self.dropPatch?.number == Self.patchCount ? Self.dropPatch?.keep : nil) {
                upload.data.append(payload.prefix(keep))
                Self.uploads[path] = upload
                return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            upload.data.append(payload)
            Self.uploads[path] = upload
            if upload.data.count == upload.length { Self.missing = [] }
            respond(204, ["Upload-Offset": String(upload.data.count)])
        case "PROPFIND":
            if Self.missing.contains(path) { return respond(404) }
            let xml = """
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response><d:href>\(path)</d:href><d:propstat><d:prop>
            <d:getetag>"after-upload"</d:getetag><d:getcontentlength>1</d:getcontentlength><oc:fileid>file-1</oc:fileid>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """
            respond(207, [:], Data(xml.utf8))
        default:
            respond(405)
        }
    }
}

actor MemoryResumeStore: TusResumeStore {
    var locations: [String: URL] = [:]
    func tusLocation(fingerprint: String) -> URL? { locations[fingerprint] }
    func saveTusLocation(_ location: URL, fingerprint: String) { locations[fingerprint] = location }
    func removeTusLocation(fingerprint: String) { locations[fingerprint] = nil }
    func count() -> Int { locations.count }
}

@main struct TusUploadTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

    static func makeFile(_ size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<size { raw[index] = UInt8(truncatingIfNeeded: index &* 2654435761 >> 7) }
        }
        try data.write(to: url)
        return url
    }

    static func client() -> WebDAVClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTusProtocol.self]
        return WebDAVClient(serverURL: URL(string: "https://cloud.example.test")!, davPath: "/dav/spaces/space-1",
                            username: "user", password: "token", useBearer: true, sessionConfiguration: configuration)
    }

    static func decodedMetadata(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in header.split(separator: ",") {
            let parts = pair.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let data = Data(base64Encoded: parts[1]) { result[parts[0]] = String(decoding: data, as: UTF8.self) }
        }
        return result
    }

    static func main() async throws {
        let chunk = Int(WebDAVClient.tusChunkSize)
        let size = 2 * chunk + 1024 * 1024
        let file = try makeFile(size)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = try Data(contentsOf: file)
        let sha1 = Insecure.SHA1.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)

        // Large file: creation-with-upload, then PATCH, with the sync engine's headers.
        MockTusProtocol.reset()
        var dav = client()
        _ = try await dav.uploadFile(from: file, to: "/folder/big.bin", ifMatchEtag: "old", progress: nil, modificationDate: mtime)
        check(MockTusProtocol.uploads.count == 1, "one TUS upload is created")
        let upload = MockTusProtocol.uploads.values.first!
        check(upload.data == expected, "the server assembles the exact file")
        check(upload.length == size, "Upload-Length announces the whole file")
        let meta = decodedMetadata(upload.metadata)
        check(meta["filename"] == "/folder/big.bin", "filename metadata is the path inside the space")
        check(meta["checksum"] == "SHA1 " + sha1, "checksum metadata uses the server's preferred type")
        check(meta["mtime"] == "1700000000", "mtime metadata preserves the modification date")
        let post = MockTusProtocol.requests.first { $0.method == "POST" }!
        check(post.path == "/dav/spaces/space-1", "uploads are created at the space root, like the sync engine")
        check(post.headers["Tus-Resumable"] == "1.0.0" && post.headers["If-Match"] == "\"old\"" && post.headers["X-OC-Mtime"] == "1700000000",
              "creation carries TUS version, conflict guard and mtime")
        let patches = MockTusProtocol.requests.filter { $0.method == "PATCH" }
        check(patches.count == 2 && patches.allSatisfy { $0.headers["If-Match"] == "\"old\"" }, "each chunk keeps the conflict guard")
        check(MockTusProtocol.putBodies.isEmpty, "large files never fall back to a single PUT")

        // A dropped connection resumes at the server's offset instead of restarting.
        MockTusProtocol.reset()
        MockTusProtocol.dropPatch = (number: 1, keep: 3 * 1024 * 1024)
        dav = client()
        _ = try await dav.uploadFile(from: file, to: "/folder/big.bin", progress: nil, modificationDate: mtime)
        let resumed = MockTusProtocol.uploads.values.first!
        check(MockTusProtocol.uploads.count == 1, "an interrupted upload continues the same TUS upload")
        check(resumed.data == expected, "resumed upload assembles the exact file")
        let heads = MockTusProtocol.requests.filter { $0.method == "HEAD" }
        check(heads.count == 1, "the client asks the server for the offset after an interruption")
        let sent = MockTusProtocol.requests.filter { $0.method == "POST" || $0.method == "PATCH" }.map(\.bodySize).reduce(0, +)
        check(sent == size + chunk - 3 * 1024 * 1024, "only bytes the server lacks are resent: \(sent) for \(size); 3 MB of the dropped chunk arrived")

        // An upload interrupted for good resumes after a relaunch from the persisted location.
        MockTusProtocol.reset()
        MockTusProtocol.failPatches = 512 * 1024
        let store = MemoryResumeStore()
        do {
            _ = try await client().uploadFile(from: file, to: "/folder/big.bin", progress: nil, modificationDate: mtime, resumeStore: store)
            preconditionFailure("a connection that keeps dropping must fail eventually")
        } catch {}
        let stored = await store.count()
        check(stored == 1, "an unfinished upload keeps its location for later")
        let partial = MockTusProtocol.uploads.values.first!.data.count
        check(partial > chunk, "the failed attempts kept their progress on the server")
        MockTusProtocol.failPatches = nil
        MockTusProtocol.requests = []
        _ = try await client().uploadFile(from: file, to: "/folder/big.bin", progress: nil, modificationDate: mtime, resumeStore: store)
        check(MockTusProtocol.uploads.count == 1 && MockTusProtocol.uploads.values.first!.data == expected,
              "a relaunched client completes the same upload with the exact file")
        check(!MockTusProtocol.requests.contains { $0.method == "POST" }, "the relaunched client does not start over")
        let resent = MockTusProtocol.requests.filter { $0.method == "PATCH" }.map(\.bodySize).reduce(0, +)
        check(resent == size - partial, "after a relaunch only the missing bytes are sent")
        let remaining = await store.count()
        check(remaining == 0, "a finished upload forgets its location")

        // Conflicts are reported, not retried or overwritten.
        MockTusProtocol.reset()
        MockTusProtocol.postStatus = 412
        dav = client()
        do {
            _ = try await dav.uploadFile(from: file, to: "/folder/big.bin", ifMatchEtag: "stale", progress: nil, modificationDate: mtime)
            preconditionFailure("a stale If-Match must fail")
        } catch WebDAVError.conflict {}
        check(MockTusProtocol.requests.filter { $0.method == "POST" }.count == 1, "a conflict is not retried")

        // A new file must not overwrite one that appeared on the server, but the guard cannot be a
        // conditional header on the creation request: that request targets the space root.
        MockTusProtocol.reset()
        MockTusProtocol.missing = ["/dav/spaces/space-1/folder/new.bin"]
        dav = client()
        let created = try await dav.uploadFile(from: file, to: "/folder/new.bin", ifNoneMatch: true, progress: nil, modificationDate: mtime)
        check(created != nil && MockTusProtocol.uploads.values.first?.data == expected, "a new large file is uploaded")
        let newPost = MockTusProtocol.requests.first { $0.method == "POST" }!
        check(newPost.headers["If-None-Match"] == nil, "the creation request carries no If-None-Match")
        check(MockTusProtocol.requests.first?.method == "PROPFIND" || MockTusProtocol.requests.prefix(2).contains { $0.method == "PROPFIND" },
              "the client checks that the target is still free before creating the upload")

        MockTusProtocol.reset()
        dav = client()
        do {
            _ = try await dav.uploadFile(from: file, to: "/folder/new.bin", ifNoneMatch: true, progress: nil, modificationDate: mtime)
            preconditionFailure("a file that appeared on the server must not be overwritten")
        } catch WebDAVError.conflict {}
        check(!MockTusProtocol.requests.contains { $0.method == "POST" }, "no upload is created over an existing file")

        // Servers without TUS keep the single-request upload.
        MockTusProtocol.reset()
        MockTusProtocol.tusExtensions = nil
        dav = client()
        _ = try await dav.uploadFile(from: file, to: "/folder/big.bin", progress: nil, modificationDate: mtime)
        check(MockTusProtocol.putBodies["/dav/spaces/space-1/folder/big.bin"] == expected, "without TUS support the file is PUT")
        check(MockTusProtocol.uploads.isEmpty, "no TUS requests without server support")

        print("FileProvider TUS upload tests passed")
    }
}
