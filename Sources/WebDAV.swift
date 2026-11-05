import Foundation
import Network

// MARK: - HTTP plumbing

struct HTTPRequest {
    let method: String
    let rawPath: String
    let version: String
    let headers: [String: String]

    var components: [String] {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return path
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
            .filter { !$0.isEmpty }
    }

    var contentLength: Int? {
        headers["content-length"].flatMap { Int($0) }
    }

    var keepAlive: Bool {
        if let value = headers["connection"]?.lowercased(), value.contains("close") { return false }
        if version == "HTTP/1.0" { return headers["connection"]?.lowercased().contains("keep-alive") ?? false }
        return true
    }

    static func parse(_ block: String) -> HTTPRequest? {
        let lines = block.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        return HTTPRequest(
            method: String(parts[0]),
            rawPath: String(parts[1]),
            version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
            headers: headers
        )
    }
}

/// Blocking wrapper around NWConnection so the HTTP logic can stay readable.
final class DAVConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "goprocard.dav.connection")
    private let lock = NSLock()
    private var buffer = Data()
    private var _closed = false

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _closed
    }

    private func markClosed() {
        lock.lock(); _closed = true; lock.unlock()
    }

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.markClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        markClosed()
        connection.cancel()
    }

    /// nil => error, empty Data => end of stream
    private func receiveChunk() -> Data? {
        if isClosed { return nil }
        var payload: Data?
        var ended = false
        let semaphore = DispatchSemaphore(value: 0)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty { payload = data }
            ended = isComplete || error != nil
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 120) == .success else {
            close()
            return nil
        }
        if let payload = payload { return payload }
        return ended ? Data() : nil
    }

    func readHeaderBlock() -> String? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                let block = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: block, encoding: .utf8)
            }
            if buffer.count > 128 * 1024 { return nil }
            guard let chunk = receiveChunk() else { return nil }
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    @discardableResult
    func readBody(count: Int) -> Bool {
        var remaining = count
        while remaining > 0 {
            if !buffer.isEmpty {
                let take = min(remaining, buffer.count)
                buffer.removeFirst(take)
                remaining -= take
                continue
            }
            guard let chunk = receiveChunk(), !chunk.isEmpty else { return false }
            buffer.append(chunk)
        }
        return true
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if isClosed { return false }

        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        connection.send(content: data, completion: .contentProcessed { error in
            succeeded = (error == nil)
            semaphore.signal()
        })

        // A client that stops reading (Spotlight, a stalled copy) would otherwise hold the
        // camera link open forever; give up on a connection that makes no progress.
        guard semaphore.wait(timeout: .now() + 25) == .success else {
            close()
            return false
        }
        if !succeeded { markClosed() }
        return succeeded
    }

    func writeHead(status: Int, reason: String, headers: [(String, String)]) -> Bool {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "Connection: keep-alive\r\n\r\n"
        return send(Data(text.utf8))
    }

    func writeSimple(status: Int, reason: String, body: String = "", close: Bool = false) {
        let payload = Data(body.utf8)
        var headers: [(String, String)] = [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Length", "\(payload.count)")
        ]
        if close {
            headers.append(("Connection", "close"))
            var text = "HTTP/1.1 \(status) \(reason)\r\n"
            for (key, value) in headers { text += "\(key): \(value)\r\n" }
            text += "\r\n"
            _ = send(Data(text.utf8))
        } else {
            _ = writeHead(status: status, reason: reason, headers: headers)
        }
        _ = send(payload)
    }
}

// MARK: - WebDAV server

final class WebDAVServer {
    /// A stable port keeps the published hostname valid across restarts, so Finder never
    /// connects to an address that used to work.
    static let preferredPort: UInt16 = 47821

    private(set) var port: UInt16
    let catalog: GoProCatalog

    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "goprocard.dav.listener")
    private var ready = false

    init(catalog: GoProCatalog) {
        self.catalog = catalog
        self.port = WebDAVServer.preferredPort
    }

    var mountURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    func start() throws {
        guard listener == nil else { return }

        var lastError: Error = GoProError.timeout
        let candidates: [UInt16] = [WebDAVServer.preferredPort, findFreePort()]

        for (index, candidate) in candidates.enumerated() {
            do {
                try startListener(port: candidate, loopbackOnly: index < candidates.count)
                log("webdav listening on 127.0.0.1:\(port)")
                return
            } catch {
                lastError = error
                listener?.cancel()
                listener = nil
                ready = false
                log("webdav bind attempt \(index + 1) on port \(candidate) failed: \(error)")
            }
        }

        // Nothing on loopback worked; bind anywhere and rely on the peer check.
        do {
            try startListener(port: findFreePort(), loopbackOnly: false)
            log("webdav listening on 127.0.0.1:\(port)")
            return
        } catch {
            lastError = error
        }
        throw lastError
    }

    private func startListener(port: UInt16, loopbackOnly: Bool) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw GoProError.http(-1) }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Binding through requiredLocalEndpoint keeps the socket on 127.0.0.1 only,
        // which also avoids the "accept incoming connections?" firewall prompt.
        let listener: NWListener
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: nwPort)
        }
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.ready = true
                semaphore.signal()
            case .failed(let error):
                log("webdav listener failed: \(error)")
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { connection.cancel(); return }
            // Only ever serve the loopback mount; refuse anything else.
            let peer = String(describing: connection.endpoint)
            guard peer.contains("127.0.0.1") || peer.contains("::1") else {
                log("rejecting non-loopback peer \(peer)")
                connection.cancel()
                return
            }
            let dav = DAVConnection(connection)
            dav.start()
            DispatchQueue.global().async {
                self.serve(dav)
            }
        }

        listener.start(queue: listenerQueue)

        guard semaphore.wait(timeout: .now() + 5) == .success, ready else {
            throw GoProError.http(-1)
        }

        if let bound = listener.port?.rawValue {
            self.port = bound
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        ready = false
    }

    // MARK: Connection loop

    private func serve(_ connection: DAVConnection) {
        defer { connection.close() }

        while true {
            guard let block = connection.readHeaderBlock(), let request = HTTPRequest.parse(block) else { return }

            if let length = request.contentLength, length > 0 {
                guard length < 16 * 1024 * 1024, connection.readBody(count: length) else { return }
            }

            let keepAlive = request.keepAlive
            handle(request, on: connection)
            if !keepAlive { return }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: DAVConnection) {
        if debugLogging {
            log("REQ \(request.method) \(request.rawPath) range=\(request.headers["range"] ?? "-") depth=\(request.headers["depth"] ?? "-")")
        }
        switch request.method {
        case "OPTIONS":
            // Class 1 only: this volume is read-only, and claiming lock support would
            // make Finder try to write into it.
            _ = connection.writeHead(status: 200, reason: "OK", headers: [
                ("DAV", "1"),
                ("Allow", "OPTIONS, GET, HEAD, PROPFIND"),
                ("MS-Author-Via", "DAV"),
                ("Content-Length", "0")
            ])

        case "PROPFIND":
            handlePropfind(request, on: connection)

        case "GET", "HEAD":
            handleGet(request, on: connection, headOnly: request.method == "HEAD")

        default:
            connection.writeSimple(status: 405, reason: "Method Not Allowed", body: "read-only volume")
        }
    }

    // MARK: PROPFIND

    private func isJunk(_ name: String) -> Bool {
        [".DS_Store", ".localized", ".TemporaryItems", ".fseventsd", ".Spotlight-V100", ".Trashes"]
            .contains(name)
    }

    private func handlePropfind(_ request: HTTPRequest, on connection: DAVConnection) {
        let components = request.components
        let depthHeader = request.headers["depth"]?.lowercased() ?? "1"
        let depth = depthHeader == "0" ? 0 : 1

        if components.contains(where: { isJunk($0) }) {
            connection.writeSimple(status: 404, reason: "Not Found")
            return
        }

        guard let entry = catalog.entry(at: components) else {
            connection.writeSimple(status: 404, reason: "Not Found")
            return
        }

        var responses: [String] = []

        if entry.isCollection {
            if components.isEmpty {
                responses.append(propResponse(components: [], entry: .collection(name: "GoPro")))
            } else {
                responses.append(propResponse(components: components, entry: entry))
            }

            if depth == 1, let children = catalog.children(of: components) {
                for child in children where !isJunk(child.name) {
                    responses.append(propResponse(components: components + [child.name], entry: child))
                }
            }
        } else {
            responses.append(propResponse(components: components, entry: entry))
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """
        let payload = Data(xml.utf8)
        _ = connection.writeHead(status: 207, reason: "Multi-Status", headers: [
            ("Content-Type", "application/xml; charset=\"utf-8\""),
            ("Content-Length", "\(payload.count)")
        ])
        _ = connection.send(payload)
    }

    private func href(for components: [String], collection: Bool) -> String {
        if components.isEmpty { return "/" }
        let encoded = components
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return "/" + encoded + (collection ? "/" : "")
    }

    private func propResponse(components: [String], entry: VirtualEntry) -> String {
        let collection = entry.isCollection
        let path = href(for: components, collection: collection)
        let isRoot = components.isEmpty
        let display = isRoot ? "GoPro" : entry.name

        var properties = "<D:displayname>\(xmlEscape(display))</D:displayname>"
        if collection {
            properties += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            properties += "<D:resourcetype/>"
            properties += "<D:getcontentlength>\(entry.size)</D:getcontentlength>"
            properties += "<D:getcontenttype>\(contentType(for: entry.name))</D:getcontenttype>"
            properties += "<D:getetag>\"\(entry.size)-\(Int((entry.modified ?? Date()).timeIntervalSince1970))\"</D:getetag>"
        }
        properties += "<D:getlastmodified>\(httpDate(entry.modified ?? Date()))</D:getlastmodified>"
        properties += "<D:creationdate>\(isoDate(entry.modified ?? Date()))</D:creationdate>"
        properties += "<D:supportedlock/><D:lockdiscovery/>"
        properties += "<D:getcontentlanguage/>"

        return """
        <D:response>
        <D:href>\(path)</D:href>
        <D:propstat>
        <D:prop>\(properties)</D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>
        """
    }

    // MARK: GET

    private func handleGet(_ request: HTTPRequest, on connection: DAVConnection, headOnly: Bool) {
        let components = request.components
        guard !components.contains(where: { isJunk($0) }) else {
            connection.writeSimple(status: 404, reason: "Not Found")
            return
        }
        guard let entry = catalog.entry(at: components) else {
            connection.writeSimple(status: 404, reason: "Not Found")
            return
        }

        switch entry {
        case .collection:
            let listing = (catalog.children(of: components) ?? []).map { $0.name }.joined(separator: "\n")
            let payload = Data(listing.utf8)
            _ = connection.writeHead(status: 200, reason: "OK", headers: [
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Content-Length", "\(payload.count)")
            ])
            _ = connection.send(payload)

        case .file(_, _, _, let remotePath):
            if remotePath.isEmpty {
                // Virtual marker file (Spotlight opt-out) — no upstream request needed.
                _ = connection.writeHead(status: 200, reason: "OK", headers: [
                    ("Content-Type", "text/plain"),
                    ("Content-Length", "0")
                ])
                return
            }
            guard let url = URL(string: "http://\(catalog.info.ip):8080\(remotePath)") else {
                connection.writeSimple(status: 502, reason: "Bad Gateway")
                return
            }

            var upstream = URLRequest(url: url)
            upstream.httpMethod = headOnly ? "HEAD" : "GET"
            upstream.timeoutInterval = 90
            if let range = cappedRange(request.headers["range"], totalSize: entry.size) {
                upstream.setValue(range, forHTTPHeaderField: "Range")
            }

            if headOnly {
                if let (status, headers) = synchronousHead(upstream) {
                    _ = connection.writeHead(status: status, reason: status == 206 ? "Partial Content" : "OK", headers: headers)
                } else {
                    connection.writeSimple(status: 502, reason: "Bad Gateway")
                }
            } else {
                ProxyDownload(connection: connection, request: upstream).run()
            }
        }
    }

    private func synchronousHead(_ request: URLRequest) -> (Int, [(String, String)])? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = HeadBox()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            box.response = response as? HTTPURLResponse
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 20) == .success, let http = box.response else { return nil }

        var headers: [(String, String)] = []
        headers.append(("Content-Type", http.mimeType ?? "application/octet-stream"))
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            headers.append(("Content-Length", length))
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range") {
            headers.append(("Content-Range", range))
        }
        if let modified = http.value(forHTTPHeaderField: "Last-Modified") {
            headers.append(("Last-Modified", modified))
        }
        headers.append(("Accept-Ranges", "bytes"))
        return (http.statusCode, headers)
    }
}

final class HeadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _response: HTTPURLResponse?
    var response: HTTPURLResponse? {
        get { lock.lock(); defer { lock.unlock() }; return _response }
        set { lock.lock(); _response = newValue; lock.unlock() }
    }
}

// MARK: - Streaming GET proxy

final class ProxyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: DAVConnection
    private let request: URLRequest
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var signalled = false
    private var bytesSent: Int64 = 0
    private var expectedLength: Int64 = -1

    init(connection: DAVConnection, request: URLRequest) {
        self.connection = connection
        self.request = request
    }

    func run() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 7200
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        let task = session.dataTask(with: request)
        self.task = task
        task.resume()

        _ = finished.wait(timeout: .now() + 7200)

        session.invalidateAndCancel()
        if let task = self.task, task.state == .running { task.cancel() }

        // If the body was not fully handed to the client (Finder/QuickTime read part of a
        // file and went quiet), close the connection. Otherwise the client waits forever
        // for bytes that are never coming.
        if expectedLength >= 0 && bytesSent < expectedLength {
            log("closing short transfer at \(bytesSent)/\(expectedLength) bytes")
            connection.close()
        }
    }

    private func finish() {
        lock.lock()
        let already = signalled
        signalled = true
        lock.unlock()
        if !already { finished.signal() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        guard let http = response as? HTTPURLResponse else {
            connection.writeSimple(status: 502, reason: "Bad Gateway")
            completionHandler(.cancel)
            finish()
            return
        }

        if http.statusCode >= 400 {
            connection.writeSimple(status: http.statusCode, reason: "Upstream Error")
            completionHandler(.cancel)
            finish()
            return
        }

        var headers: [(String, String)] = []
        headers.append(("Content-Type", http.mimeType ?? contentType(for: request.url?.lastPathComponent ?? "")))
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            headers.append(("Content-Length", length))
            expectedLength = Int64(length) ?? -1
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range") {
            headers.append(("Content-Range", range))
        }
        if let modified = http.value(forHTTPHeaderField: "Last-Modified") {
            headers.append(("Last-Modified", modified))
        }
        if let etag = http.value(forHTTPHeaderField: "Etag") {
            headers.append(("ETag", etag))
        }
        headers.append(("Accept-Ranges", "bytes"))

        let reason = http.statusCode == 206 ? "Partial Content" : "OK"
        if !connection.writeHead(status: http.statusCode, reason: reason, headers: headers) {
            completionHandler(.cancel)
            finish()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isCancelled || connection.isClosed {
            dataTask.cancel()
            finish()
            return
        }
        if !connection.send(data) {
            lock.lock(); cancelled = true; lock.unlock()
            dataTask.cancel()
            finish()
            return
        }
        bytesSent += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, !isCancelled {
            log("proxy download error: \(error.localizedDescription)")
        }
        finish()
    }
}

// MARK: - Formatting helpers

let debugLogging = ProcessInfo.processInfo.environment["GOPROCARD_DEBUG"] == "1"

/// How much of an open-ended range request we are willing to stream in one response.
let rangeChunkSize: Int64 = 4 * 1024 * 1024

/// The macOS WebDAV client asks for "everything from offset N to the end of the file".
/// Forwarding that verbatim means a 200 MB transfer that must drain even after the app
/// closes the file — which stalls `cp`, `dd` and Finder. Answer in bounded slices instead;
/// the client simply asks for the next slice when it needs more.
func cappedRange(_ header: String?, totalSize: Int64) -> String? {
    guard let header = header else { return nil }
    guard header.lowercased().hasPrefix("bytes=") else { return header }

    let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
    // Only rewrite the simple open-ended form; explicit ranges and multi-ranges pass through.
    guard spec.hasSuffix("-") else { return header }

    let startText = spec.dropLast().trimmingCharacters(in: .whitespaces)
    guard let start = Int64(startText), start >= 0, totalSize > 0 else { return header }

    let end = min(start + rangeChunkSize - 1, totalSize - 1)
    guard end >= start else { return header }
    return "bytes=\(start)-\(end)"
}

func xmlEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func contentType(for name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "mp4", "m4v": return "video/mp4"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gpr": return "application/octet-stream"
    case "lrv": return "video/mp4"
    case "360": return "video/mp4"
    case "wav": return "audio/wav"
    case "thm": return "image/jpeg"
    default: return "application/octet-stream"
    }
}

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
}()

func httpDate(_ date: Date) -> String { httpDateFormatter.string(from: date) }

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func isoDate(_ date: Date) -> String { isoFormatter.string(from: date) }
