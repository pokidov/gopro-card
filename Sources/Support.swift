import Foundation
import Darwin

// MARK: - Logging

final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "goprocard.log")
    private var handle: FileHandle?

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("GoProCard.log")
    }

    private init() {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // keep the log from growing without bound
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_500_000 {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                self.handle?.write(data)
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

func log(_ message: String) { Log.shared.write(message) }

// MARK: - Process helpers

struct ProcResult {
    let status: Int32
    let out: String
    let err: String

    var ok: Bool { status == 0 }
    var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
}

@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> ProcResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return ProcResult(status: -1, out: "", err: "\(error)")
    }

    // Read concurrently so a full pipe buffer can never deadlock the child.
    let collector = OutputCollector()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        collector.out = outPipe.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: group) {
        collector.err = errPipe.fileHandleForReading.readDataToEndOfFile()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = group.wait(timeout: .now() + 2)
        return ProcResult(status: -2, out: collector.outString, err: "timed out after \(Int(timeout))s")
    }

    process.waitUntilExit()
    return ProcResult(status: process.terminationStatus, out: collector.outString, err: collector.errString)
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()

    var out: Data {
        get { lock.lock(); defer { lock.unlock() }; return _out }
        set { lock.lock(); _out = newValue; lock.unlock() }
    }

    var err: Data {
        get { lock.lock(); defer { lock.unlock() }; return _err }
        set { lock.lock(); _err = newValue; lock.unlock() }
    }

    var outString: String { String(data: out, encoding: .utf8) ?? "" }
    var errString: String { String(data: err, encoding: .utf8) ?? "" }
}

/// Start a long-running helper (e.g. `dns-sd`) that we only need the side effect of.
@discardableResult
func spawnDetached(_ path: String, _ args: [String]) -> Process? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
        return process
    } catch {
        log("spawn failed \(path): \(error)")
        return nil
    }
}

/// Run a shell command as root, showing the standard macOS administrator prompt.
func runAsAdministrator(_ shellCommand: String, prompt: String? = nil) -> ProcResult {
    let escaped = shellCommand
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    var script = "do shell script \"\(escaped)\""
    if let prompt = prompt {
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        script += " with prompt \"\(escapedPrompt)\""
    }
    script += " with administrator privileges"
    return run("/usr/bin/osascript", ["-e", script], timeout: 180)
}

// MARK: - Ports

func findFreePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return 47821 }
    defer { close(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0

    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return 47821 }

    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &result) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(fd, sockaddrPointer, &length)
        }
    }
    guard named == 0 else { return 47821 }
    return UInt16(bigEndian: result.sin_port)
}

// MARK: - Mount table

struct MountedVolume {
    let source: String
    let path: String
    let isWebDAV: Bool
}

enum MountTable {
    static func volumes() -> [MountedVolume] {
        let result = run("/sbin/mount", [])
        return result.trimmed
            .split(separator: "\n")
            .compactMap { line -> MountedVolume? in
                // http://host:port/ on /Volumes/name (webdav, ...)
                let text = String(line)
                guard let range = text.range(of: " on ") else { return nil }
                let source = String(text[text.startIndex..<range.lowerBound])
                let rest = text[range.upperBound...]
                var path = String(rest)
                if let paren = path.range(of: " (") {
                    path = String(path[path.startIndex..<paren.lowerBound])
                }
                return MountedVolume(source: source, path: path, isWebDAV: text.contains("(webdav"))
            }
    }

    static func webDAVPath(containing needle: String) -> String? {
        volumes().first { $0.isWebDAV && $0.source.contains(needle) }?.path
    }

    static func isMounted(path: String) -> Bool {
        let target = canonical(path)
        return volumes().contains { canonical($0.path) == target }
    }

    /// /tmp is a symlink to /private/tmp and the mount table always reports the real path.
    static func canonical(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}

// MARK: - Filesystem helpers

enum FSUtil {
    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isWritableDirectory(_ path: String) -> Bool {
        isDirectory(path) && FileManager.default.isWritableFile(atPath: path)
    }

    static func isEmptyDirectory(_ path: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return items.isEmpty
    }

    static func removeIfEmptyDirectory(_ path: String) {
        guard isDirectory(path), isEmptyDirectory(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A crashed WebDAV unmount can leave its mount point with execute-only permissions.
    /// These directories belong to the current user, so they can be put right again.
    static func repairPermissions(_ path: String) -> Bool {
        guard isDirectory(path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(getuid()) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return isWritableDirectory(path)
    }

    static func appSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GoPro Card", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        var text = String(mapped)
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        while text.hasPrefix("-") { text.removeFirst() }
        while text.hasSuffix("-") { text.removeLast() }
        return text.isEmpty ? "gopro" : text
    }
}
