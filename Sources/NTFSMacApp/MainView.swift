import AppKit
import NTFSKit

/// Shared state between the AppDelegate (privileged CLI work) and the window.
final class AppModel {
    var volumes: [NTFSVolume] = [] { didSet { onChange() } }
    var busy = Set<String>() { didSet { onChange() } }
    var fuseInstalled = true
    /// False until the first drive scan finishes (diskutil can take a few seconds).
    var scanned = false
    var onChange: () -> Void = {}
    var onMount: (String, Bool) -> Void = { _, _ in }
    var onUnmount: (String, Bool) -> Void = { _, _ in }
    var autoMount = false
    var onToggleAutoMount: (Bool) -> Void = { _ in }
}

private extension NSToolbarItem.Identifier {
    static let nav = Self("nav"), viewMode = Self("viewMode"), newFolder = Self("newFolder")
    static let deleteItem = Self("delete"), actions = Self("actions"), search = Self("search")
}

/// Finder-style window: source-list sidebar of drives, unified toolbar, file browser.
/// It is the window's delegate, so menu actions sent to the first responder end up here.
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSSearchFieldDelegate {
    let window: NSWindow
    let model: AppModel
    private let split = NSSplitViewController()
    private let sidebar = SidebarController()
    private let browser: BrowserController
    private let navControl = NSSegmentedControl()
    private let viewControl = NSSegmentedControl()
    private var searchItem: NSSearchToolbarItem?
    private var newFolderItem: NSToolbarItem?
    private var deleteItem: NSToolbarItem?
    private var actionsItem: NSMenuToolbarItem?
    private var selectedID: String?

    init(model: AppModel) {
        self.model = model
        browser = BrowserController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "NTFS Mac"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 380)
        window.delegate = self
        window.toolbarStyle = .unified

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 170; sideItem.maximumThickness = 320; sideItem.canCollapse = true
        let mainItem = NSSplitViewItem(viewController: browser)
        mainItem.minimumThickness = 420
        split.addSplitViewItem(sideItem); split.addSplitViewItem(mainItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1000, height: 620))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        sidebar.onSelect = { [weak self] id in self?.selectDrive(id) }
        sidebar.onEject = { [weak self] id in self?.model.onUnmount(id, true) }
        sidebar.onToggleAutoMount = { [weak self] on in self?.model.onToggleAutoMount(on) }
        browser.onStateChange = { [weak self] in self?.updateChrome() }
        model.onChange = { [weak self] in self?.sync() }
        sync()
    }

    // MARK: Drives

    private var current: NTFSVolume? { model.volumes.first { $0.id == selectedID } }

    private func sync() {
        let vols = model.volumes
        if selectedID == nil || !vols.contains(where: { $0.id == selectedID }) {
            // Prefer the drive picked last time (by label: BSD ids change between plugs),
            // then one already mounted read-write.
            let last = UserDefaults.standard.string(forKey: "lastDrive")
            selectedID = (vols.first { $0.label == last && !$0.label.isEmpty }
                ?? vols.first { $0.rwMountPoint != nil } ?? vols.first)?.id
        }
        sidebar.update(volumes: vols, busy: model.busy, autoMount: model.autoMount)
        sidebar.select(selectedID)
        browser.show(current, busy: selectedID.map { model.busy.contains($0) } ?? false)
    }

    private func selectDrive(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        if let v = current { UserDefaults.standard.set(v.label, forKey: "lastDrive") }
        sync()
        browser.focusFiles()
    }

    // MARK: Chrome

    private func updateChrome() {
        window.title = browser.folderTitle
        window.subtitle = ""
        navControl.setEnabled(browser.canGoBack, forSegment: 0)
        navControl.setEnabled(browser.canGoForward, forSegment: 1)
        viewControl.selectedSegment = browser.mode.rawValue
        viewControl.isEnabled = browser.isMounted
        newFolderItem?.isEnabled = browser.isMounted
        deleteItem?.isEnabled = browser.isMounted && !browser.selectedNodes.isEmpty
        searchItem?.searchField.isEnabled = browser.isMounted
        if let f = searchItem?.searchField, f.stringValue != browser.filter { f.stringValue = browser.filter }
        searchItem?.searchField.placeholderString = browser.isMounted ? "Search “\(browser.folderTitle)”" : "Search"
        actionsItem?.menu = actionMenu()
    }

    private func actionMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector, _ state: Bool? = nil) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self
            if let s = state { i.state = s ? .on : .off }
            m.addItem(i)
        }
        if let v = current {
            if v.rwMountPoint != nil {
                add("New Folder", #selector(newFolder(_:)))
                add("Show in Finder", #selector(revealInFinder(_:)))
                m.addItem(.separator())
                add("Unmount “\(v.displayName)”", #selector(unmountDrive(_:)))
                add("Eject “\(v.displayName)”", #selector(ejectDrive(_:)))
            } else {
                add("Mount Read-Write", #selector(mountDrive(_:)))
                add("Discard Windows Hibernation & Mount…", #selector(forceMountDrive(_:)))
                if v.roMountPoint != nil { add("Eject “\(v.displayName)”", #selector(ejectDrive(_:))) }
            }
            m.addItem(.separator())
        }
        add("Mount Drives Automatically When Plugged In", #selector(toggleAutoMount(_:)), model.autoMount)
        return m
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .nav, .flexibleSpace, .viewMode, .newFolder, .deleteItem, .actions, .search]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t) + [.toggleSidebar, .space, .flexibleSpace]
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .nav:
            navControl.segmentCount = 2
            navControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"), forSegment: 0)
            navControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"), forSegment: 1)
            navControl.trackingMode = .momentary
            navControl.segmentStyle = .separated
            navControl.target = self; navControl.action = #selector(navClicked)
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = navControl; i.label = "Back/Forward"; i.isNavigational = true
            return i
        case .viewMode:
            viewControl.segmentCount = 2
            viewControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons"), forSegment: 0)
            viewControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 1)
            viewControl.setToolTip("as Icons", forSegment: 0); viewControl.setToolTip("as List", forSegment: 1)
            viewControl.trackingMode = .selectOne
            viewControl.target = self; viewControl.action = #selector(viewModeClicked)
            viewControl.selectedSegment = browser.mode.rawValue
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = viewControl; i.label = "View"
            return i
        case .newFolder:
            let i = button(id, "folder.badge.plus", "New Folder", #selector(newFolder(_:)))
            newFolderItem = i; return i
        case .deleteItem:
            let i = button(id, "trash", "Delete", #selector(deleteItems(_:)))
            i.toolTip = "Delete immediately (NTFS drives have no Trash)"
            deleteItem = i; return i
        case .actions:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Action")
            i.label = "Action"; i.toolTip = "Drive actions"; i.showsIndicator = true
            i.menu = actionMenu()
            actionsItem = i; return i
        case .search:
            let i = NSSearchToolbarItem(itemIdentifier: id)
            i.searchField.delegate = self
            i.searchField.target = self; i.searchField.action = #selector(searchChanged(_:))
            i.label = "Search"
            searchItem = i; return i
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ sel: Selector) -> NSToolbarItem {
        let i = NSToolbarItem(itemIdentifier: id)
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        i.label = label; i.paletteLabel = label; i.toolTip = label
        i.isBordered = true; i.autovalidates = false
        i.target = self; i.action = sel
        return i
    }

    @objc private func navClicked() { navControl.selectedSegment == 0 ? browser.goBack() : browser.goForward() }
    @objc private func viewModeClicked() { browser.setMode(ViewMode(rawValue: viewControl.selectedSegment) ?? .list) }
    @objc private func searchChanged(_ sender: NSSearchField) { browser.setFilter(sender.stringValue) }
    func controlTextDidChange(_ n: Notification) {
        if let f = n.object as? NSSearchField { browser.setFilter(f.stringValue) }
    }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { browser.setFilter("") }

    // MARK: Menu actions (reach us through the responder chain as the window's delegate)

    @objc func newFolder(_ s: Any?) { browser.newFolder() }
    @objc func openItems(_ s: Any?) { browser.openSelection() }
    @objc func rename(_ s: Any?) { browser.renameSelection() }
    @objc func duplicate(_ s: Any?) { browser.duplicateSelection() }
    @objc func deleteItems(_ s: Any?) { browser.deleteSelection() }
    @objc func quickLook(_ s: Any?) { browser.toggleQuickLook() }
    @objc func revealInFinder(_ s: Any?) { browser.revealInFinder() }
    @objc func copy(_ s: Any?) { browser.copySelection() }
    @objc func paste(_ s: Any?) { browser.paste() }
    @objc func goBack(_ s: Any?) { browser.goBack() }
    @objc func goForward(_ s: Any?) { browser.goForward() }
    @objc func goEnclosing(_ s: Any?) { browser.goEnclosing() }
    @objc func viewAsIcons(_ s: Any?) { browser.setMode(.icons) }
    @objc func viewAsList(_ s: Any?) { browser.setMode(.list) }
    @objc func focusSearch(_ s: Any?) { searchItem?.beginSearchInteraction() }
    @objc func mountDrive(_ s: Any?) { browser.mountTapped() }
    @objc func forceMountDrive(_ s: Any?) { browser.forceMountTapped() }
    @objc func unmountDrive(_ s: Any?) { if let v = current { model.onUnmount(v.id, false) } }
    @objc func ejectDrive(_ s: Any?) { if let v = current { model.onUnmount(v.id, true) } }
    @objc func toggleAutoMount(_ s: Any?) { model.onToggleAutoMount(!model.autoMount) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let mounted = browser.isMounted
        let hasSel = mounted && !browser.selectedNodes.isEmpty
        let v = current
        let busy = v.map { model.busy.contains($0.id) } ?? true
        switch item.action {
        case #selector(newFolder(_:)), #selector(revealInFinder(_:)), #selector(focusSearch(_:)): return mounted
        case #selector(openItems(_:)), #selector(duplicate(_:)), #selector(deleteItems(_:)),
             #selector(quickLook(_:)), #selector(copy(_:)): return hasSel
        case #selector(rename(_:)): return mounted && browser.selectedNodes.count == 1
        case #selector(paste(_:)): return browser.canPaste
        case #selector(goBack(_:)): return browser.canGoBack
        case #selector(goForward(_:)): return browser.canGoForward
        case #selector(goEnclosing(_:)): return mounted && !browser.atRoot
        case #selector(viewAsIcons(_:)): item.state = browser.mode == .icons ? .on : .off; return mounted
        case #selector(viewAsList(_:)): item.state = browser.mode == .list ? .on : .off; return mounted
        case #selector(mountDrive(_:)), #selector(forceMountDrive(_:)): return v != nil && !mounted && !busy
        case #selector(unmountDrive(_:)): return mounted && !busy
        case #selector(ejectDrive(_:)): return v.map { $0.rwMountPoint != nil || $0.roMountPoint != nil } == true && !busy
        case #selector(toggleAutoMount(_:)): item.state = model.autoMount ? .on : .off; return true
        default: return true
        }
    }

    // MARK: Window

    func windowDidBecomeKey(_ n: Notification) {
        // Pick up changes made elsewhere (e.g. in Finder) when the user comes back.
        if browser.isMounted { browser.reload() }
    }
}
