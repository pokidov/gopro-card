import AppKit
import Foundation

// MARK: - Login item

enum LoginItem {
    static let label = "com.gopromount.goprocard"

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func enable() -> Bool {
        let directory = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>--background</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        do {
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            log("could not write launch agent: \(error)")
            return false
        }

        let uid = getuid()
        let bootstrap = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath], timeout: 15)
        if !bootstrap.ok {
            _ = run("/bin/launchctl", ["load", "-w", plistPath], timeout: 15)
        }
        return true
    }

    @discardableResult
    static func disable() -> Bool {
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15)
        _ = run("/bin/launchctl", ["unload", "-w", plistPath], timeout: 15)
        try? FileManager.default.removeItem(atPath: plistPath)
        return true
    }
}

// MARK: - Single instance guard

enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func claim() -> Bool {
        let path = FSUtil.appSupport().appendingPathComponent("instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = MountController()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("GoPro Card \(Bundle.main.appVersion) starting")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sdcard", accessibilityDescription: "GoPro Card")
            button.image?.isTemplate = true
            button.toolTip = "GoPro Card"
        }

        Store.shared.start()
        statusItem?.menu = buildMenu()
        controller.onChange = { [weak self] in self?.refreshMenu() }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.controller.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        controller.tick()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        controller.shutdown()
    }

    // MARK: Menu

    private var menu: NSMenu?

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        self.menu = menu
        rebuild(menu)
        return menu
    }

    private func refreshMenu() {
        guard let menu = menu else { return }
        rebuild(menu)
        if let button = statusItem?.button {
            let symbol: String
            switch controller.state {
            case .mounted: symbol = "sdcard.fill"
            case .mounting, .searching: symbol = "sdcard"
            case .failed: symbol = "exclamationmark.triangle"
            case .idle: symbol = "sdcard"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GoPro Card")
            button.image?.isTemplate = true
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if let camera = controller.camera {
            let header = NSMenuItem(title: "\(camera.model) · \(camera.ip)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Camera Files in Finder", action: #selector(showInFinder), keyEquivalent: "")
        show.target = self
        show.isEnabled = controller.state.isMounted
        menu.addItem(show)

        if controller.state.isMounted {
            let eject = NSMenuItem(title: "Unmount Camera", action: #selector(unmount), keyEquivalent: "")
            eject.target = self
            menu.addItem(eject)
        } else {
            let mount = NSMenuItem(title: "Mount Camera Now", action: #selector(mountNow), keyEquivalent: "")
            mount.target = self
            mount.isEnabled = controller.camera != nil
            menu.addItem(mount)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        if let camera = controller.camera,
           !FSUtil.isWritableDirectory("/Volumes/\(camera.volumeName)") {
            let pretty = NSMenuItem(title: "Use Camera Name as Disk Name…", action: #selector(prepareMountPoint), keyEquivalent: "")
            pretty.target = self
            menu.addItem(pretty)
        }

        if !Store.shared.isUnlocked {
            let unlock = NSMenuItem(title: "Unlock GoPro Card…", action: #selector(unlockPro), keyEquivalent: "")
            unlock.target = self
            menu.addItem(unlock)
        }

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit GoPro Card", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func showInFinder() {
        if let path = controller.mountPath, FSUtil.isDirectory(path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    @objc private func mountNow() {
        controller.remount()
        refreshMenu()
    }

    @objc private func unmount() {
        controller.teardown(unmount: true, reason: "menu")
        refreshMenu()
    }

    @objc private func toggleLogin() {
        if LoginItem.isEnabled {
            LoginItem.disable()
        } else {
            LoginItem.enable()
        }
        refreshMenu()
    }

    @objc private func prepareMountPoint() {
        let alert = NSAlert()
        alert.messageText = "Use the camera name as the disk name?"
        alert.informativeText = """
        This creates a mount point in /Volumes so the camera appears with its real name \
        (for example “HERO13 Black”) instead of a generic folder. macOS will ask for your \
        administrator password once.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = controller.prepareNiceMountPoint()
        refreshMenu()
    }

    @objc private func unlockPro() {
        let alert = Store.shared.makePaywallAlert()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { await Store.shared.purchase() }
        } else if response == .alertSecondButtonReturn {
            Task { await Store.shared.restore() }
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    @objc private func quit() {
        controller.shutdown()
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
