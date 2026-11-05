import Foundation

// MARK: - Model

struct CameraInfo: Equatable {
    var model: String
    var serial: String
    var firmware: String
    var ip: String
    var interfaceName: String

    var volumeName: String { model.isEmpty ? "GoPro" : model }

    var slug: String {
        FSUtil.slug(model.isEmpty ? "gopro" : model)
    }

    /// Opens the camera's embedded web server. The camera ignores the Host header,
    /// so this works for both the DHCP-discovered and the serial-derived address.
    var baseURL: URL { URL(string: "http://\(ip):8080")! }
}

struct MediaFile {
    let directory: String
    let name: String
    let size: Int64
    let modified: Date
}

enum VirtualEntry {
    case collection(name: String)
    case file(name: String, size: Int64, modified: Date, remotePath: String)

    var name: String {
        switch self {
        case .collection(let name): return name
        case .file(let name, _, _, _): return name
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    var size: Int64 {
        if case .file(_, let size, _, _) = self { return size }
        return 0
    }

    var modified: Date? {
        if case .file(_, _, let modified, _) = self { return modified }
        return nil
    }
}

// MARK: - Discovery

enum GoProFinder {
    /// Interfaces that look like the camera's USB Ethernet adapter: RFC1918 172.16/12.
    static func candidateInterfaces() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let sockaddrPointer = entry.ifa_addr, sockaddrPointer.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: entry.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(sockaddrPointer.pointee.sa_len)
                if getnameinfo(sockaddrPointer, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: host)
                    if address.hasPrefix("172.") {
                        result.append((name, address))
                    }
                }
            }
            cursor = entry.ifa_next
        }
        return result
    }

    /// The camera hands out its own address over DHCP; ask the interface for its router.
    static func router(forInterface name: String) -> String? {
        let result = run("/usr/sbin/ipconfig", ["getoption", name, "router"], timeout: 3)
        let value = result.trimmed
        guard result.ok, !value.isEmpty, value.hasPrefix("172.") else { return nil }
        return value
    }

    /// The documented fallback address is 172.2X.1YZ.51 where XYZ are the last three
    /// digits of the camera's serial number.
    static func addressFromSerial(_ serial: String) -> String? {
        let digits = serial.filter { $0.isNumber }
        guard digits.count >= 3 else { return nil }
        let tail = Array(digits.suffix(3)).map(String.init)
        return "172.2\(tail[0]).1\(tail[1])\(tail[2]).51"
    }

    static func probe(ip: String, interface: String?, timeout: TimeInterval = 1.6) -> CameraInfo? {
        guard let url = URL(string: "http://\(ip):8080/gopro/camera/info") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, _, _ in
            box.data = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1.2)
        session.invalidateAndCancel()

        guard let data = box.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serial = json["serial_number"] as? String
        else { return nil }

        return CameraInfo(
            model: json["model_name"] as? String ?? "GoPro",
            serial: serial,
            firmware: json["firmware_version"] as? String ?? "",
            ip: ip,
            interfaceName: interface ?? ""
        )
    }

    static func locate(interfaceHint: String? = nil, forcedIP: String? = nil) -> CameraInfo? {
        if let forcedIP = forcedIP {
            return probe(ip: forcedIP, interface: nil)
        }

        let interfaces = candidateInterfaces()
        var ordered: [(name: String, address: String)] = interfaces
        if let hint = interfaceHint,
           let match = interfaces.first(where: { $0.name == hint }) {
            ordered = [match] + interfaces.filter { $0.name != hint }
        }

        for entry in ordered {
            if let gateway = router(forInterface: entry.name), let camera = probe(ip: gateway, interface: entry.name) {
                return camera
            }
        }

        // Last resort: derive the address from the serial number seen on the USB bus.
        for serial in usbSerials() {
            if let ip = addressFromSerial(serial), let camera = probe(ip: ip, interface: nil) {
                return camera
            }
        }
        return nil
    }

    /// Serial numbers of attached GoPro USB devices (vendor id 0x2672).
    static func usbSerials() -> [String] {
        let result = run("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-w0"], timeout: 5)
        guard result.ok else { return [] }
        var serials: [String] = []
        for line in result.out.split(separator: "\n") {
            let text = String(line)
            guard text.contains("\"USB Serial Number\"") else { continue }
            if let equals = text.range(of: " = ") {
                let value = text[equals.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { serials.append(value) }
            }
        }
        return serials
    }

    static func hasGoProUSBDevice() -> Bool {
        let result = run("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-w0"], timeout: 5)
        guard result.ok else { return false }
        return result.out.contains("\"idVendor\" = 9842")
    }
}

final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    var data: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); _data = newValue; lock.unlock() }
    }
}

// MARK: - Media catalog

final class GoProCatalog {
    let info: CameraInfo

    private let lock = NSLock()
    private var directories: [String: [MediaFile]] = [:]
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private let refreshQueue = DispatchQueue(label: "gopro.card.refresh", qos: .utility)

    init(info: CameraInfo) {
        self.info = info
    }

    /// Fetches the listing synchronously. Only used when the camera is first attached.
    func refresh() throws {
        let url = info.baseURL.appendingPathComponent("gopro/media/list")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let statusBox = StatusBox()
        let errorBox = ErrorBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            statusBox.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            errorBox.error = error
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 25) == .timedOut {
            throw GoProError.timeout
        }
        if let error = errorBox.error { throw error }
        guard statusBox.status == 200, let data = box.data else {
            throw GoProError.http(statusBox.status)
        }

        let parsed = try Self.parse(data)
        lock.lock()
        directories = parsed
        lastRefresh = Date()
        lock.unlock()
    }

    /// Never blocks a caller: kicks off a refresh in the background when the snapshot is old.
    /// Path lookups always answer from the cached listing so Finder stays responsive even
    /// while the camera is busy streaming a large file.
    func backgroundRefresh(maxAge: TimeInterval = 12) {
        lock.lock()
        let stale = Date().timeIntervalSince(lastRefresh) > maxAge
        let alreadyRefreshing = refreshing
        if stale && !alreadyRefreshing { refreshing = true }
        lock.unlock()

        guard stale && !alreadyRefreshing else { return }

        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.refresh()
            self.lock.lock()
            self.refreshing = false
            self.lock.unlock()
        }
    }

    static func parse(_ data: Data) throws -> [String: [MediaFile]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = root["media"] as? [[String: Any]]
        else { throw GoProError.badPayload }

        var result: [String: [MediaFile]] = [:]
        for group in media {
            // Firmware >= 2.0 uses short keys (d/fs/n/s/mod); older uses long ones.
            let directory = (group["d"] as? String) ?? (group["directory"] as? String) ?? "100GOPRO"
            let files = (group["fs"] as? [[String: Any]]) ?? (group["files"] as? [[String: Any]]) ?? []

            var parsed: [MediaFile] = []
            for file in files {
                let name = (file["n"] as? String) ?? (file["name"] as? String) ?? ""
                guard !name.isEmpty else { continue }

                let sizeText = (file["s"] as? String) ?? (file["size"] as? String) ?? "0"
                let timeText = (file["mod"] as? String) ?? (file["time"] as? String) ?? (file["cre"] as? String) ?? ""
                let size = Int64(sizeText) ?? 0
                parsed.append(MediaFile(directory: directory, name: name, size: size, modified: parseDate(timeText)))
            }
            parsed.sort { $0.name < $1.name }
            result[directory] = parsed
        }
        return result
    }

    static func parseDate(_ text: String) -> Date {
        if let epoch = TimeInterval(text), epoch > 1_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        return Date()
    }

    // MARK: Virtual filesystem

    func children(of components: [String]) -> [VirtualEntry]? {
        backgroundRefresh()

        lock.lock()
        let snapshot = directories
        lock.unlock()

        if components.isEmpty {
            return [.collection(name: "DCIM")]
        }
        if components == ["DCIM"] {
            return snapshot.keys.sorted().map { .collection(name: $0) }
        }
        if components.count == 2, components[0] == "DCIM" {
            guard let files = snapshot[components[1]] else { return nil }
            return files.map { file in
                .file(name: file.name,
                      size: file.size,
                      modified: file.modified,
                      remotePath: "/videos/DCIM/\(file.directory)/\(file.name)")
            }
        }
        return nil
    }

    /// An empty marker file that tells Spotlight not to index this volume. Without it
    /// macOS tries to read every file on the card, which floods the camera's USB link.
    static let noIndexMarker = ".metadata_never_index"

    func entry(at components: [String]) -> VirtualEntry? {
        if components == [GoProCatalog.noIndexMarker] {
            return .file(name: GoProCatalog.noIndexMarker,
                         size: 0,
                         modified: Date(timeIntervalSince1970: 1_600_000_000),
                         remotePath: "")
        }
        if components.isEmpty { return .collection(name: "") }
        if components.count == 1, components[0] == "DCIM" { return .collection(name: "DCIM") }
        guard let siblings = children(of: Array(components.dropLast())) else { return nil }
        return siblings.first { $0.name == components.last }
    }
}

enum GoProError: Error, CustomStringConvertible {
    case timeout
    case http(Int)
    case badPayload

    var description: String {
        switch self {
        case .timeout: return "camera did not respond"
        case .http(let code): return "camera returned HTTP \(code)"
        case .badPayload: return "unexpected media listing"
        }
    }
}

final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status = 0
    var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); _error = newValue; lock.unlock() }
    }
}
