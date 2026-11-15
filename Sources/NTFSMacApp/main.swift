import AppKit
import NTFSKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var volumes: [NTFSVolume] = []
    private var busy = Set<String>()
    private let queue = DispatchQueue(label: "ntfsmac.work")
    private var timer: Timer?
    private let model = AppModel()
    private lazy var windowController = MainWindowController(model: model)

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        windowController.window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
    @objc private func showWindowAction() { showWindow() }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: "NTFS Mac")
            b.toolTip = "NTFS Mac"
        }
        menu.delegate = self
        statusItem.menu = menu
        model.onMount = { [weak self] id, force in
            if force {
                guard self?.confirm("Discard Windows hibernation data?",
                    "This deletes the hibernation file. Anything Windows had open when it hibernated is lost. Only continue if you don't need that session.") == true else { return }
            }
            self?.runPrivileged(force ? ["mount", "--force"] : ["mount"], id: id, done: "mounted")
        }
        model.onUnmount = { [weak self] id, eject in
            self?.runPrivileged(eject ? ["unmount", "--eject"] : ["unmount"], id: id, done: "unmounted")
        }
        showWindow()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: State

    private func refresh() {
        queue.async { [weak self] in
            let v = Discovery.ntfsVolumes()
            DispatchQueue.main.async {
                self?.volumes = v
                self?.model.volumes = v
                self?.model.fuseInstalled = Mounter.fuseTInstalled()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let w = NSMenuItem(title: "Open NTFS Mac Window", action: #selector(showWindowAction), keyEquivalent: "")
        w.target = self; menu.addItem(w); menu.addItem(.separator())
        volumes = Discovery.ntfsVolumes() // fresh list when the user opens the menu

        if !Mounter.fuseTInstalled() {
            menu.addItem(withTitle: "FUSE-T is not installed", action: nil, keyEquivalent: "").isEnabled = false
            let i = NSMenuItem(title: "Copy install command", action: #selector(copyFuseCmd), keyEquivalent: "")
            i.target = self; menu.addItem(i); menu.addItem(.separator())
        }
        if volumes.isEmpty {
            menu.addItem(withTitle: "No NTFS drives connected", action: nil, keyEquivalent: "").isEnabled = false
        }
        for v in volumes {
            let size = ByteCountFormatter.string(fromByteCount: v.sizeBytes, countStyle: .file)
            let state = busy.contains(v.id) ? "working…" : (v.isMountedRW ? "read-write" : (v.roMountPoint != nil ? "read-only" : "not mounted"))
            let item = NSMenuItem(title: "\(v.displayName)  (\(size)) — \(state)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if busy.contains(v.id) {
                item.isEnabled = false
            } else if let mp = v.rwMountPoint {
                sub.addItem(action("Open in Finder", #selector(openFinder(_:)), v.id, mp))
                sub.addItem(action("Unmount", #selector(unmount(_:)), v.id))
                sub.addItem(action("Unmount && Eject", #selector(eject(_:)), v.id))
            } else {
                sub.addItem(action("Mount Read-Write…", #selector(mount(_:)), v.id))
                sub.addItem(action("Mount Read-Write, discard Windows hibernation…", #selector(mountForce(_:)), v.id))
                if let ro = v.roMountPoint { sub.addItem(action("Open Read-Only in Finder", #selector(openFinder(_:)), v.id, ro)) }
            }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NTFS Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func action(_ title: String, _ sel: Selector, _ id: String, _ path: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = path.map { [id, $0] } ?? [id]
        return i
    }

    // MARK: Actions

    private func ids(_ s: NSMenuItem) -> [String] { (s.representedObject as? [String]) ?? [] }

    @objc private func openFinder(_ s: NSMenuItem) {
        if let p = ids(s).dropFirst().first { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }
    @objc private func copyFuseCmd() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install --cask macos-fuse-t/cask/fuse-t", forType: .string)
    }
    @objc private func mount(_ s: NSMenuItem) { runPrivileged(["mount"], id: ids(s).first, done: "mounted") }
    @objc private func mountForce(_ s: NSMenuItem) {
        guard confirm("Discard Windows hibernation data?",
                      "This deletes the hibernation file. Anything Windows had open when it hibernated is lost. Only continue if you don't need that session.") else { return }
        runPrivileged(["mount", "--force"], id: ids(s).first, done: "mounted")
    }
    @objc private func unmount(_ s: NSMenuItem) { runPrivileged(["unmount"], id: ids(s).first, done: "unmounted") }
    @objc private func eject(_ s: NSMenuItem) { runPrivileged(["unmount", "--eject"], id: ids(s).first, done: "ejected") }

    private func runPrivileged(_ sub: [String], id: String?, done: String) {
        guard let id = id, (try? Mounter.validate(id: id)) != nil else { return }
        guard let cli = cliPath() else { return alert("ntfsmac CLI not found next to the app.") }
        busy.insert(id); model.busy = busy
        let cmd = "NTFSMAC_UID=\(getuid()) NTFSMAC_GID=\(getgid()) \(shq(cli)) \((sub + [id]).joined(separator: " "))"
        let script = "do shell script \"\(asEscape(cmd))\" with administrator privileges"
        queue.async { [weak self] in
            let r = Shell.run("/usr/bin/osascript", ["-e", script])
            DispatchQueue.main.async {
                self?.busy.remove(id); self?.model.busy = self?.busy ?? []
                if r.status != 0 {
                    let msg = r.stderr.contains("-128") ? nil : r.stderr   // -128 = user cancelled
                    if let msg = msg { self?.alert(Self.clean(msg)) }
                }
                self?.refresh()
            }
        }
    }

    // MARK: Helpers

    private func cliPath() -> String? {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let p = dir.appendingPathComponent("ntfsmac").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func asEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private static func clean(_ s: String) -> String {
        // osascript prefixes errors with "NN:NN execution error: ... (1)"
        s.replacingOccurrences(of: #"^\d+:\d+: execution error: "#, with: "", options: .regularExpression)
         .replacingOccurrences(of: #" \(\d+\)\s*$"#, with: "", options: .regularExpression)
    }
    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "NTFS Mac"; a.informativeText = text; a.runModal()
    }
    private func confirm(_ title: String, _ text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Discard & Mount")
        return a.runModal() == .alertSecondButtonReturn
    }
}

let app = NSApplication.shared
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu(); appItem.submenu = appMenu
appMenu.addItem(withTitle: "Quit NTFS Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
app.mainMenu = mainMenu
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
