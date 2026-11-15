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
        model.autoMount = Helper.isInstalled
        model.onToggleAutoMount = { [weak self] on in self?.setAutoMount(on) }
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
                self?.model.fuseInstalled = Mounter.fuseTInstalled()
                self?.model.scanned = true
                self?.model.volumes = v
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
        let auto = NSMenuItem(title: "Mount Automatically When Plugged In", action: #selector(toggleAutoMount), keyEquivalent: "")
        auto.target = self; auto.state = Helper.isInstalled ? .on : .off
        menu.addItem(auto)
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
        queue.async { [weak self] in
            // With the helper installed, sudoers lets us run its CLI without a password.
            var r: ShellResult? = Helper.isInstalled ? Shell.run("/usr/bin/sudo", ["-n", Helper.cliPath] + sub + [id]) : nil
            if let e = r?.stderr, e.contains("password is required") || e.contains("not allowed") { r = nil }
            let res = r ?? Self.runAsAdmin(cli, sub + [id])
            DispatchQueue.main.async {
                self?.busy.remove(id); self?.model.busy = self?.busy ?? []
                if res.status != 0 {
                    let msg = res.stderr.contains("-128") ? nil : res.stderr   // -128 = user cancelled
                    if let msg = msg { self?.alert(Self.clean(msg)) }
                }
                self?.refresh()
            }
        }
    }

    /// Runs the CLI as root via the standard macOS admin-password prompt.
    private static func runAsAdmin(_ cli: String, _ args: [String]) -> ShellResult {
        let cmd = "NTFSMAC_UID=\(getuid()) NTFSMAC_GID=\(getgid()) \(shq(cli)) " + args.map(shq).joined(separator: " ")
        return Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(asEscape(cmd))\" with administrator privileges"])
    }

    private func setAutoMount(_ on: Bool) {
        guard let cli = cliPath() else { return alert("ntfsmac CLI not found next to the app.") }
        queue.async { [weak self] in
            let r = Self.runAsAdmin(cli, [on ? "install-helper" : "uninstall-helper"])
            DispatchQueue.main.async {
                if r.status != 0, !r.stderr.contains("-128") { self?.alert(Self.clean(r.stderr)) }
                self?.model.autoMount = Helper.isInstalled
                self?.model.onChange()
                self?.refresh()
            }
        }
    }
    @objc private func toggleAutoMount() { setAutoMount(!Helper.isInstalled) }

    // MARK: Helpers

    private func cliPath() -> String? {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let p = dir.appendingPathComponent("ntfsmac").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func asEscape(_ s: String) -> String {
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

// MARK: Main menu (Finder's names and shortcuts). Items have no target, so they travel the
// responder chain to text fields first, then to MainWindowController (the window's delegate).

let app = NSApplication.shared
let mainMenu = NSMenu()

func submenu(_ title: String) -> NSMenu {
    let item = NSMenuItem(); mainMenu.addItem(item)
    let m = NSMenu(title: title); item.submenu = m; return m
}
@discardableResult
func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let i = m.addItem(withTitle: title, action: sel, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    return i
}
func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
typealias W = MainWindowController

let appMenu = submenu("NTFS Mac")
add(appMenu, "About NTFS Mac", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
appMenu.addItem(.separator())
add(appMenu, "Hide NTFS Mac", #selector(NSApplication.hide(_:)), "h")
add(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
add(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
appMenu.addItem(.separator())
add(appMenu, "Quit NTFS Mac", #selector(NSApplication.terminate(_:)), "q")

let fileMenu = submenu("File")
add(fileMenu, "New Folder", #selector(W.newFolder(_:)), "n", [.command, .shift])
add(fileMenu, "Open", #selector(W.openItems(_:)), "o")
add(fileMenu, "Close Window", #selector(NSWindow.performClose(_:)), "w")
fileMenu.addItem(.separator())
add(fileMenu, "Delete Immediately…", #selector(W.deleteItems(_:)), "\u{8}")
fileMenu.addItem(.separator())
add(fileMenu, "Rename", #selector(W.rename(_:)))
add(fileMenu, "Duplicate", #selector(W.duplicate(_:)), "d")
add(fileMenu, "Quick Look", #selector(W.quickLook(_:)), "y")
add(fileMenu, "Show in Finder", #selector(W.revealInFinder(_:)), "r", [.command, .option])
fileMenu.addItem(.separator())
add(fileMenu, "Eject", #selector(W.ejectDrive(_:)), "e")

let editMenu = submenu("Edit")
add(editMenu, "Undo", Selector(("undo:")), "z")
add(editMenu, "Redo", Selector(("redo:")), "z", [.command, .shift])
editMenu.addItem(.separator())
add(editMenu, "Cut", #selector(NSText.cut(_:)), "x")
add(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
add(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
add(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a")
editMenu.addItem(.separator())
add(editMenu, "Find", #selector(W.focusSearch(_:)), "f")

let viewMenu = submenu("View")
add(viewMenu, "as Icons", #selector(W.viewAsIcons(_:)), "1")
add(viewMenu, "as List", #selector(W.viewAsList(_:)), "2")
viewMenu.addItem(.separator())
add(viewMenu, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
add(viewMenu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

let goMenu = submenu("Go")
add(goMenu, "Back", #selector(W.goBack(_:)), "[")
add(goMenu, "Forward", #selector(W.goForward(_:)), "]")
add(goMenu, "Enclosing Folder", #selector(W.goEnclosing(_:)), arrow(NSUpArrowFunctionKey))
add(goMenu, "Open Selection", #selector(W.openItems(_:)), arrow(NSDownArrowFunctionKey))

let driveMenu = submenu("Drive")
add(driveMenu, "Mount Read-Write", #selector(W.mountDrive(_:)), "m", [.command, .shift])
add(driveMenu, "Discard Windows Hibernation & Mount…", #selector(W.forceMountDrive(_:)))
add(driveMenu, "Unmount", #selector(W.unmountDrive(_:)), "u", [.command, .shift])
add(driveMenu, "Eject", #selector(W.ejectDrive(_:)))
driveMenu.addItem(.separator())
add(driveMenu, "Mount Drives Automatically When Plugged In", #selector(W.toggleAutoMount(_:)))

let windowMenu = submenu("Window")
add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
app.windowsMenu = windowMenu

app.mainMenu = mainMenu
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
