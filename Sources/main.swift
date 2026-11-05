import AppKit
import Foundation

// MARK: - Command line handling

let arguments = CommandLine.arguments

func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func printUsage() {
    print("""
    GoPro Card — mount a GoPro over USB as a normal macOS volume

    USAGE
      GoPro Card.app                 menu bar app (double-click)
      GoProCard --doctor             show what the app can see right now
      GoProCard --mount <path>       mount at an explicit path and stay in the foreground
      GoProCard --unmount <path>     unmount a volume

    OPTIONS
      --background    run the menu bar app (used by the login item)
      --verbose       verbose logging to stderr
    """)
}

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

// MARK: - Doctor

if arguments.contains("--doctor") {
    print("GoPro Card diagnostics")
    print("---------------------")

    let interfaces = GoProFinder.candidateInterfaces()
    if interfaces.isEmpty {
        print("USB network interfaces: none (is the camera connected and set to GoPro Connect?)")
    } else {
        print("USB network interfaces:")
        for entry in interfaces {
            let router = GoProFinder.router(forInterface: entry.name) ?? "unknown"
            print("  \(entry.name)  \(entry.address)  gateway: \(router)")
        }
    }

    let serials = GoProFinder.usbSerials()
    print("GoPro USB serials: \(serials.isEmpty ? "none" : serials.joined(separator: ", "))")
    print("GoPro USB device present: \(GoProFinder.hasGoProUSBDevice() ? "yes" : "no")")

    if let camera = GoProFinder.locate() {
        print("Camera: \(camera.model)  serial \(camera.serial)  firmware \(camera.firmware)")
        print("Address: http://\(camera.ip):8080")
        do {
            let catalog = GoProCatalog(info: camera)
            try catalog.refresh()
            let directories = catalog.children(of: []) ?? []
            print("Top level: \(directories.map { $0.name }.joined(separator: ", "))")
            if let folders = catalog.children(of: ["DCIM"]) {
                for folder in folders {
                    let files = catalog.children(of: ["DCIM", folder.name]) ?? []
                    let total = files.reduce(Int64(0)) { $0 + $1.size }
                    print("  DCIM/\(folder.name): \(files.count) files, \(String(format: "%.1f", Double(total) / 1e9)) GB")
                }
            }
        } catch {
            print("Media listing failed: \(error)")
        }
    } else {
        print("Camera: not found")
    }

    let volumes = MountTable.volumes().filter { $0.isWebDAV }
    print("Mounted WebDAV volumes: \(volumes.isEmpty ? "none" : volumes.map { $0.path }.joined(separator: ", "))")
    exit(0)
}

// MARK: - Headless mount (testing / scripting)

if let mountPath = flagValue("--mount") {
    if !SingleInstance.claim() {
        FileHandle.standardError.write(Data("another GoPro Card instance is already running\n".utf8))
        exit(2)
    }

    guard let camera = GoProFinder.locate() else {
        print("No GoPro found.")
        exit(1)
    }

    let catalog = GoProCatalog(info: camera)
    do {
        try catalog.refresh()
    } catch {
        print("Could not read the camera media list: \(error)")
        exit(1)
    }

    let server = WebDAVServer(catalog: catalog)
    do {
        try server.start()
    } catch {
        print("Could not start the WebDAV bridge: \(error)")
        exit(1)
    }

    try? FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
    let plan = MountPlan(path: mountPath, method: .direct)
    var process: Process?
    let mountedAt = MountStrategy.mount(plan: plan, camera: camera, url: server.mountURL, keepAlive: &process)

    guard let mountedAt = mountedAt else {
        print("Mount failed. See \(Log.shared.fileURL.path)")
        exit(1)
    }

    print("Mounted \(camera.model) at \(mountedAt) (bridge: \(server.mountURL.absoluteString))")
    print("Press Ctrl-C to unmount and quit.")

    var signalSources: [DispatchSourceSignal] = []
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            MountStrategy.unmount(path: mountedAt)
            server.stop()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    // Keep serving until interrupted.
    while true {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if !MountTable.isMounted(path: mountedAt) {
            print("Volume disappeared; exiting.")
            break
        }
    }
    server.stop()
    exit(0)
}

if let unmountPath = flagValue("--unmount") {
    let ok = MountStrategy.unmount(path: unmountPath)
    print(ok ? "Unmounted \(unmountPath)" : "Could not unmount \(unmountPath)")
    exit(ok ? 0 : 1)
}

if arguments.contains("--enable-login") {
    guard LoginItem.enable() else {
        print("Could not enable login item")
        exit(1)
    }
    print("GoPro Card will start automatically at login")
    exit(0)
}

if arguments.contains("--disable-login") {
    LoginItem.disable()
    print("Login item disabled")
    exit(0)
}

if arguments.contains("--status") {
    print("login item: \(LoginItem.isEnabled ? "enabled" : "disabled")")
    let volumes = MountTable.volumes().filter { $0.isWebDAV }
    print("mounted: \(volumes.isEmpty ? "nothing" : volumes.map { $0.path }.joined(separator: ", "))")
    exit(0)
}

if arguments.contains("--prepare-volume") {
    guard let camera = GoProFinder.locate() else {
        print("No GoPro found — connect the camera and try again.")
        exit(1)
    }
    guard MountStrategy.prepareVolumeDirectory(for: camera) else {
        print("Could not create the mount point (cancelled?)")
        exit(1)
    }
    print("Created /Volumes/\(camera.volumeName) — the camera will mount there from now on.")
    exit(0)
}

// MARK: - Menu bar app

guard SingleInstance.claim() else {
    // Already running; bring the existing instance forward by doing nothing.
    exit(0)
}

MountBookmark.cleanupStale()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
