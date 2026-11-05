import Foundation

// MARK: - Mount planning

struct MountPlan {
    enum Method {
        case direct      // our own mount_webdav call
        case finder      // let Finder's privileged helper create the mount point
    }

    let path: String
    let method: Method
}

enum MountStrategy {
    static let volumesRoot = "/Volumes"

    /// Set when macOS refuses to let us talk to Finder. Manual mounts clear it again.
    static var finderMountBlocked: Bool {
        get { UserDefaults.standard.bool(forKey: "finderMountBlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "finderMountBlocked") }
    }

    /// Order of preference:
    ///  1. /Volumes/<Camera Name>      — exists (one-time admin setup) → prettiest
    ///  2. /Volumes/<camera-slug>.local — created earlier by the Finder helper → no privileges
    ///  3. create /Volumes/<Camera Name> ourselves — works only if /Volumes is writable
    ///  4. bootstrap through Finder's mount helper → real disk, still no root
    ///  5. app support folder         — always works, just not a disk
    static func plan(for camera: CameraInfo) -> MountPlan {
        let pretty = "\(volumesRoot)/\(camera.volumeName)"

        if FSUtil.isWritableDirectory(pretty) {
            return MountPlan(path: pretty, method: .direct)
        }
        if let existing = existingVolumeDirectory(slug: camera.slug) {
            return MountPlan(path: existing, method: .direct)
        }
        if createDirectoryIfPossible(pretty) {
            return MountPlan(path: pretty, method: .direct)
        }
        if !finderMountBlocked {
            return MountPlan(path: "\(volumesRoot)/\(camera.slug).local", method: .finder)
        }
        let fallback = FSUtil.appSupport()
            .appendingPathComponent("Mounts", isDirectory: true)
            .appendingPathComponent(camera.volumeName, isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return MountPlan(path: fallback.path, method: .direct)
    }

    /// A previous mount may have left a usable directory behind under the plain name or a
    /// "-1"/"-2" variant (Finder suffixes the name when one already exists).
    static func existingVolumeDirectory(slug: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: volumesRoot) else { return nil }

        let matches = entries
            .filter { $0 == "\(slug).local" || $0.hasPrefix("\(slug).local-") }
            .sorted()

        for name in matches {
            let path = "\(volumesRoot)/\(name)"
            if FSUtil.isWritableDirectory(path) { return path }
            if FSUtil.repairPermissions(path) { return path }
        }
        return nil
    }

    private static func createDirectoryIfPossible(_ path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return FSUtil.isWritableDirectory(path) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            return FSUtil.isWritableDirectory(path)
        } catch {
            return false
        }
    }

    /// /Volumes always exists; it is writable only when the admin helper prepared it.
    private static var isVolumesDirectoryUsable: Bool {
        FileManager.default.isWritableFile(atPath: volumesRoot)
    }

    // MARK: Execution

    @discardableResult
    static func mount(plan: MountPlan, camera: CameraInfo, url: URL, keepAlive: inout Process?) -> String? {
        switch plan.method {
        case .direct:
            return mountDirect(plan: plan, url: url) ? plan.path : nil

        case .finder:
            return mountViaFinder(camera: camera, url: url, keepAlive: &keepAlive)
        }
    }

    private static func mountDirect(plan: MountPlan, url: URL) -> Bool {
        if MountTable.isMounted(path: plan.path) {
            return true
        }
        let result = run("/sbin/mount_webdav", ["-S", url.absoluteString, plan.path], timeout: 45)
        if !result.ok {
            log("mount_webdav failed (\(result.status)): \(result.err)\(result.out)")
            return false
        }
        return MountTable.isMounted(path: plan.path)
    }

    /// Finder performs the mount through NetAuthSysAgent, which is allowed to create
    /// directories in /Volumes and hands the mount point to the current user.
    /// Returns the path Finder actually used — it appends "-1", "-2"… when a directory
    /// with the preferred name already exists.
    private static func mountViaFinder(camera: CameraInfo, url: URL, keepAlive: inout Process?) -> String? {
        let host = "\(camera.slug).local"
        let portToken = ":\(url.port ?? 80)/"

        if let already = MountTable.webDAVPath(containing: portToken) { return already }

        let port = Int(url.port ?? 80)
        ensureHostname(host, port: port, process: &keepAlive)
        guard waitForHostname(host, port: port) else {
            log("could not publish \(host); falling back")
            return nil
        }

        let script = "mount volume \"http://\(host):\(port)/\""
        let result = run("/usr/bin/osascript", ["-e", script], timeout: 30)
        guard result.ok else {
            let text = result.err + result.out
            if text.contains("-1743") || text.lowercased().contains("not authorized") {
                // Automation permission is required once; remember so we don't stall again.
                MountStrategy.finderMountBlocked = true
                log("Finder automation is not authorised; using a plain folder instead")
            }
            log("finder mount failed: \(text)")
            return nil
        }

        for _ in 0..<40 {
            if let mounted = MountTable.webDAVPath(containing: portToken) {
                log("Finder mounted the camera at \(mounted)")
                return mounted
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("finder mount did not appear")
        return nil
    }

    static func registerHostname(_ host: String, port: Int, process: inout Process?) {
        let base = host.replacingOccurrences(of: ".local", with: "")
        // A leftover registration from an earlier run would point Finder at a dead port.
        _ = run("/usr/bin/pkill", ["-f", "dns-sd -P \(base) "], timeout: 3)
        process = spawnDetached("/usr/bin/dns-sd",
                                ["-P", base, "_webdav._tcp", "local", "\(port)", host, "127.0.0.1"])
    }

    /// Republish only when the advertised port is wrong. Restarting a healthy registration
    /// would briefly withdraw the A record and make Finder fail to resolve the name.
    private static func ensureHostname(_ host: String, port: Int, process: inout Process?) {
        let base = host.replacingOccurrences(of: ".local", with: "")
        let existing = run("/usr/bin/pgrep", ["-fl", "dns-sd -P \(base) "], timeout: 3).trimmed

        if !existing.isEmpty {
            let alreadyCorrect = existing
                .split(separator: "\n")
                .contains { $0.contains(" \(port) \(host) ") }
            if alreadyCorrect { return }
            log("replacing stale hostname registration")
        }
        registerHostname(host, port: port, process: &process)
    }

    /// DNS alone is not enough: a cached record can point at a port that no longer listens,
    /// which makes Finder sit and wait.
    private static func reachable(_ host: String, port: Int) -> Bool {
        run("/usr/bin/nc", ["-z", "-G", "1", "-w", "2", host, "\(port)"], timeout: 4).ok
    }

    private static func waitForHostname(_ host: String, port: Int) -> Bool {
        for _ in 0..<20 {
            if reachable(host, port: port) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    // MARK: Unmount

    /// A volume that Finder mounted is best ejected by Finder itself; it owns the mount
    /// through its privileged helper and returns in a fraction of a second. Driving
    /// `diskutil` against the same volume from a helper process can hang indefinitely.
    static func ejectViaFinder(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to eject disk \"\(escaped)\""
        _ = run("/usr/bin/osascript", ["-e", script], timeout: 10)
        return !MountTable.isMounted(path: path)
    }

    @discardableResult
    static func unmount(path: String) -> Bool {
        if !MountTable.isMounted(path: path) { return true }

        if ejectViaFinder(path: path) { return true }

        var result = run("/usr/sbin/diskutil", ["unmount", path], timeout: 6)
        if result.ok { return true }

        result = run("/sbin/umount", [path], timeout: 6)
        if result.ok { return true }

        log("gentle unmount failed, forcing")
        _ = run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 6)
        if MountTable.isMounted(path: path) {
            _ = run("/sbin/umount", ["-f", path], timeout: 6)
        }
        return !MountTable.isMounted(path: path)
    }

    /// Removing a WebDAV volume from inside the process that serves it blocks until the
    /// mount helper gives up, so hand the job to a short-lived detached shell instead.
    static func unmountDetached(path: String) {
        let safe = path.replacingOccurrences(of: "\"", with: "\\\"")
        let logPath = FSUtil.appSupport().appendingPathComponent("unmount.log").path
        let script = """
        exec >> "\(logPath)" 2>&1
        echo "--- $(date '+%H:%M:%S') unmounting \(safe)"
        /usr/sbin/diskutil unmount "\(safe)"
        echo "diskutil exit=$?"
        if /sbin/mount | /usr/bin/grep -qF "on \(safe) "; then
            echo "still mounted, forcing"
            /sbin/umount -f "\(safe)"
            echo "umount exit=$?"
        fi
        if /sbin/mount | /usr/bin/grep -qF "on \(safe) "; then echo "RESULT still-mounted"; else echo "RESULT gone"; fi
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
    }

    /// Optional one-time setup: creates /Volumes/<Camera Name> owned by the current user,
    /// which lets later mounts be plain `mount_webdav` calls with the camera's real name.
    ///
    /// The directory is seeded with a keeper file: unmounting a WebDAV volume removes its
    /// mount point when it is empty, and without this the point would vanish after the
    /// first eject and the camera would fall back to the Finder-created `.local` name.
    static func prepareVolumeDirectory(for camera: CameraInfo) -> Bool {
        let path = "\(volumesRoot)/\(camera.volumeName)"
        if FSUtil.isWritableDirectory(path) && FileManager.default.fileExists(atPath: path + "/.keep") {
            return true
        }

        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "mkdir -p '\(escaped)'"
            + " && touch '\(escaped)/.keep'"
            + " && chown -R \(getuid()):\(getgid()) '\(escaped)'"
            + " && chmod 755 '\(escaped)'"
        let result = runAsAdministrator(command,
                                        prompt: "GoPro Card needs your password once, to create a disk named “\(camera.volumeName)” in /Volumes. After this the camera always mounts there automatically.")
        if result.ok {
            log("prepared mount point \(path)")
            return FSUtil.isWritableDirectory(path)
        }
        log("prepare failed: \(result.err)")
        return false
    }
}

// MARK: - Stale mount recovery

/// Remembers what we mounted so a crash cannot leave a dead WebDAV volume behind.
enum MountBookmark {
    private static var url: URL {
        FSUtil.appSupport().appendingPathComponent("last-mount.txt")
    }

    static func save(_ path: String) {
        try? path.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// If a previous run died while a volume was mounted, that volume now points at a
    /// server that no longer exists and will hang Finder. Force it away at launch.
    static func cleanupStale() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { clear(); return }

        if MountTable.isMounted(path: path) {
            log("cleaning up stale mount at \(path)")
            _ = run("/sbin/umount", ["-f", path], timeout: 20)
            if MountTable.isMounted(path: path) {
                _ = run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 20)
            }
        }
        clear()
    }
}

// MARK: - Controller

final class MountController {
    enum State: Equatable {
        case idle
        case searching
        case mounting
        case mounted(path: String)
        case failed(String)

        var isMounted: Bool {
            if case .mounted = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle {
        didSet {
            if state != oldValue {
                log("state: \(describe(state))")
                DispatchQueue.main.async { self.onChange?() }
                onStateChange?(state)
            }
        }
    }

    private(set) var camera: CameraInfo?
    private(set) var mountPath: String?
    var onChange: (() -> Void)?
    var onStateChange: ((State) -> Void)?

    private var server: WebDAVServer?
    private var hostnameProcess: Process?
    private var lastSearch = Date.distantPast
    private var lastHealthCheck = Date.distantPast
    private var lastUSBScan = Date.distantPast
    private var probeFailures = 0
    private var usbDevicePresent = false
    private var busy = false
    private var mtpSince: Date?

    var statusText: String {
        switch state {
        case .idle:
            return "Looking for a GoPro…"
        case .searching:
            return "Looking for a GoPro…"
        case .mounting:
            return "Mounting \(camera?.volumeName ?? "camera")…"
        case .mounted(let path):
            return "\(camera?.volumeName ?? "GoPro") mounted at \(path)"
        case .failed(let message):
            return message
        }
    }

    private func describe(_ state: State) -> String {
        switch state {
        case .idle: return "idle"
        case .searching: return "searching"
        case .mounting: return "mounting"
        case .mounted(let path): return "mounted(\(path))"
        case .failed(let message): return "failed(\(message))"
        }
    }

    // MARK: Loop

    func tick() {
        guard !busy else { return }

        if let camera = camera, let path = mountPath {
            checkHealth(camera: camera, path: path)
            return
        }

        guard Date().timeIntervalSince(lastSearch) > 2 else { return }
        lastSearch = Date()

        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let found = GoProFinder.locate()
            DispatchQueue.main.async {
                self.busy = false
                if let found = found {
                    self.connect(to: found)
                } else {
                    self.noteMissingCamera()
                }
            }
        }
    }

    private func noteMissingCamera() {
        if state.isMounted { return }

        // Scanning the USB tree is comparatively expensive; do it occasionally.
        if Date().timeIntervalSince(lastUSBScan) > 15 {
            lastUSBScan = Date()
            usbDevicePresent = GoProFinder.hasGoProUSBDevice()
            if usbDevicePresent {
                if mtpSince == nil { mtpSince = Date() }
            } else {
                mtpSince = nil
            }
        }

        if usbDevicePresent, let since = mtpSince, Date().timeIntervalSince(since) > 10 {
            state = .failed("GoPro is connected but not reachable. Set Preferences ▸ Connections ▸ USB Connection ▸ GoPro Connect.")
        } else if !state.isFailed {
            state = .searching
        }
    }

    private func checkHealth(camera: CameraInfo, path: String) {
        if !MountTable.isMounted(path: path) {
            log("volume disappeared from mount table")
            teardown(unmount: false, reason: "volume was ejected")
            return
        }
        guard Date().timeIntervalSince(lastHealthCheck) > 5 else { return }
        lastHealthCheck = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let alive = GoProFinder.probe(ip: camera.ip, interface: camera.interfaceName, timeout: 2.0) != nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                if alive {
                    self.probeFailures = 0
                    return
                }
                // A single missed probe is normal while the camera is busy streaming;
                // only give up once it has been unreachable for a while.
                self.probeFailures += 1
                log("camera probe failed (\(self.probeFailures)/3)")
                if self.probeFailures >= 3 {
                    self.probeFailures = 0
                    self.teardown(unmount: true, reason: "camera disconnected")
                }
            }
        }
    }

    // MARK: Connect

    private func connect(to camera: CameraInfo) {
        guard !busy else { return }
        busy = true
        self.camera = camera
        state = .mounting

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let catalog = GoProCatalog(info: camera)
            do {
                try catalog.refresh()
            } catch {
                log("media listing failed: \(error)")
                DispatchQueue.main.async {
                    self.busy = false
                    self.camera = nil
                    self.state = .failed("Connected, but the camera did not return its media list.")
                }
                return
            }

            let server = WebDAVServer(catalog: catalog)
            do {
                try server.start()
            } catch {
                log("webdav server failed: \(error)")
                DispatchQueue.main.async {
                    self.busy = false
                    self.camera = nil
                    self.state = .failed("Could not start the local media bridge.")
                }
                return
            }

            let plan = MountStrategy.plan(for: camera)
            var process = self.hostnameProcess
            var mountedPath = MountStrategy.mount(plan: plan, camera: camera, url: server.mountURL, keepAlive: &process)

            if mountedPath == nil, plan.method == .direct, !MountStrategy.finderMountBlocked {
                // The directory we picked is unusable (a stale mount point from an unclean
                // shutdown returns EBUSY); let Finder choose a fresh name instead.
                let finderPlan = MountPlan(path: "\(MountStrategy.volumesRoot)/\(camera.slug).local",
                                           method: .finder)
                mountedPath = MountStrategy.mount(plan: finderPlan, camera: camera, url: server.mountURL, keepAlive: &process)
            }

            if mountedPath == nil {
                // Last resort: a plain folder that always works, just not a drive.
                let fallback = FSUtil.appSupport()
                    .appendingPathComponent("Mounts", isDirectory: true)
                    .appendingPathComponent(camera.volumeName, isDirectory: true)
                try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                let fallbackPlan = MountPlan(path: fallback.path, method: .direct)
                mountedPath = MountStrategy.mount(plan: fallbackPlan, camera: camera, url: server.mountURL, keepAlive: &process)
            }

            DispatchQueue.main.async {
                self.busy = false
                self.hostnameProcess = process
                if let mountedPath = mountedPath {
                    self.server = server
                    self.mountPath = mountedPath
                    MountBookmark.save(mountedPath)
                    self.state = .mounted(path: mountedPath)
                } else {
                    server.stop()
                    if let process = process, process.isRunning { process.terminate() }
                    self.hostnameProcess = nil
                    self.camera = nil
                    self.state = .failed("Could not mount the camera.")
                }
            }
        }
    }

    // MARK: Teardown

    func teardown(unmount: Bool = true, reason: String = "manual") {
        guard camera != nil || server != nil || mountPath != nil else { return }
        log("tearing down (\(reason))")

        let path = mountPath
        let server = self.server
        let process = hostnameProcess

        self.mountPath = nil
        self.server = nil
        self.camera = nil
        self.hostnameProcess = nil
        self.state = .idle

        DispatchQueue.global(qos: .userInitiated).async {
            if unmount, let path = path {
                if MountStrategy.unmount(path: path) {
                    MountBookmark.clear()
                }
            } else {
                MountBookmark.clear()
            }
            server?.stop()
            if let process = process, process.isRunning {
                process.terminate()
            }
        }
    }

    /// Blocks until the camera is unmounted — used when the app is quitting, because a
    /// background teardown would be killed along with the process.
    func shutdown() {
        let path = mountPath
        let server = self.server
        let process = hostnameProcess

        mountPath = nil
        self.server = nil
        camera = nil
        hostnameProcess = nil

        if let path = path {
            MountBookmark.clear()
            if !MountStrategy.ejectViaFinder(path: path) {
                // Not a Finder mount, or Finder refused — let a detached helper finish it.
                MountStrategy.unmountDetached(path: path)
                for _ in 0..<30 {
                    if !MountTable.isMounted(path: path) { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        server?.stop()
        if let process = process, process.isRunning { process.terminate() }
    }

    func remount() {
        MountStrategy.finderMountBlocked = false
        teardown(unmount: true, reason: "manual remount")
        lastSearch = .distantPast
        tick()
    }

    func prepareNiceMountPoint() -> Bool {
        guard let camera = camera else { return false }
        let ok = MountStrategy.prepareVolumeDirectory(for: camera)
        if ok {
            // Re-mount so the new, prettier mount point is used.
            remount()
        }
        return ok
    }
}
