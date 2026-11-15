import AppKit
import Quartz
import UniformTypeIdentifiers
import NTFSKit

enum ViewMode: Int { case icons = 0, list = 1 }

/// The Finder-like file area: list (with disclosure triangles) or icon view, path bar and status bar.
final class BrowserController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let model: AppModel
    var onStateChange: () -> Void = {}

    private(set) var volume: NTFSVolume?
    private(set) var root: URL?
    private(set) var dir: URL?
    private var back: [URL] = [], forward: [URL] = []
    private var allNodes: [FileNode] = []
    private(set) var nodes: [FileNode] = []
    private var sort = FileSort()
    private(set) var filter = ""
    private(set) var mode: ViewMode
    private var activity: String?
    private var busy = false
    private var freeSpace: Int64?
    private var pathURLs: [URL] = []
    private var placeholderKey = ""
    private var renameOriginal: String?

    let outline = FileOutlineView()
    let collection = FileCollectionView()
    private let listScroll = NSScrollView(), iconScroll = NSScrollView()
    private let placeholder = PlaceholderView()
    private let pathControl = NSPathControl()
    private let pathSep = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusSpinner = NSProgressIndicator()

    init(model: AppModel) {
        self.model = model
        mode = ViewMode(rawValue: UserDefaults.standard.object(forKey: "viewMode") as? Int ?? ViewMode.list.rawValue) ?? .list
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: State for the window/toolbar

    var isMounted: Bool { root != nil }
    var canGoBack: Bool { isMounted && !back.isEmpty }
    var canGoForward: Bool { isMounted && !forward.isEmpty }
    var atRoot: Bool { dir?.standardizedFileURL == root?.standardizedFileURL }
    var folderTitle: String {
        guard let v = volume else { return "NTFS Mac" }
        guard let d = dir, !atRoot else { return v.displayName }
        return d.lastPathComponent
    }
    var selectedNodes: [FileNode] {
        switch mode {
        case .list: return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
        case .icons: return collection.selectionIndexPaths.map(\.item).sorted().filter { $0 < nodes.count }.map { nodes[$0] }
        }
    }
    private var activeView: NSView { mode == .list ? outline : collection }

    // MARK: Layout

    override func loadView() {
        let v = NSView()

        // List view
        outline.browser = self
        for (id, title, width, align) in [("name", "Name", 340.0, NSTextAlignment.left), ("date", "Date Modified", 170.0, .left),
                                           ("size", "Size", 80.0, .right), ("kind", "Kind", 130.0, .left)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = width; c.minWidth = 60
            c.headerCell.alignment = align
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .custom; outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.allowsMultipleSelection = true
        outline.autosaveName = "FileList"; outline.autosaveTableColumns = true
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(listDoubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        listScroll.documentView = outline
        listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true

        // Icon view
        collection.browser = self
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 112)
        layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        collection.collectionViewLayout = layout
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.dataSource = self; collection.delegate = self
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        iconScroll.documentView = collection
        iconScroll.hasVerticalScroller = true; iconScroll.autohidesScrollers = true

        // Path bar + status bar
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: 11)
        pathControl.backgroundColor = .clear
        pathControl.target = self; pathControl.action = #selector(pathClicked)
        pathSep.boxType = .separator
        let topSep = NSBox(); topSep.boxType = .separator
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center; statusLabel.lineBreakMode = .byTruncatingTail
        statusSpinner.style = .spinning; statusSpinner.controlSize = .small; statusSpinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [statusSpinner, statusLabel])
        statusRow.orientation = .horizontal; statusRow.spacing = 6

        let content = NSView()
        for s in [listScroll, iconScroll, placeholder] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(s)
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: content.topAnchor), s.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                s.leadingAnchor.constraint(equalTo: content.leadingAnchor), s.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        for s in [content, topSep, pathControl, pathSep, statusRow] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            topSep.topAnchor.constraint(equalTo: content.bottomAnchor),
            topSep.leadingAnchor.constraint(equalTo: v.leadingAnchor), topSep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            pathControl.topAnchor.constraint(equalTo: topSep.bottomAnchor, constant: 2),
            pathControl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            pathControl.heightAnchor.constraint(equalToConstant: 20),
            pathSep.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 2),
            pathSep.leadingAnchor.constraint(equalTo: v.leadingAnchor), pathSep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: pathSep.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 24),
            statusRow.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 8),
            statusRow.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        applyMode()
    }

    // MARK: Drive state

    func show(_ v: NTFSVolume?, busy b: Bool) {
        volume = v; busy = b
        let newRoot = v?.rwMountPoint.map { URL(fileURLWithPath: $0) }
        if newRoot != root {
            root = newRoot; dir = newRoot; back = []; forward = []; filter = ""
            reload(select: [])
        }
        updatePlaceholder()
        updateStatus()
        onStateChange()
    }

    private func updatePlaceholder() {
        let fuse = model.fuseInstalled
        let v = volume
        let key = "\(model.scanned)|\(fuse)|\(v?.id ?? "")|\(v?.displayName ?? "")|\(v?.roMountPoint ?? "")|\(isMounted)|\(busy)"
        let visible = !isMounted
        placeholder.isHidden = !visible
        listScroll.isHidden = !visible ? mode != .list : true
        iconScroll.isHidden = !visible ? mode != .icons : true
        pathControl.isHidden = !isMounted; pathSep.isHidden = !isMounted
        guard visible, key != placeholderKey else { return }
        placeholderKey = key

        func btn(_ t: String, _ sel: Selector, primary: Bool = false) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded; b.controlSize = .large
            if primary { b.keyEquivalent = "\r" }
            return b
        }
        if !model.scanned {
            placeholder.set(icon: Self.driveIcon, title: "Looking for NTFS Drives…", detail: "", buttons: [], busy: true)
        } else if !fuse {
            placeholder.set(icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil),
                            title: "FUSE-T Is Not Installed",
                            detail: "NTFS Mac needs FUSE-T to write to NTFS drives. Install it with Homebrew:\nbrew install --cask macos-fuse-t/cask/fuse-t",
                            buttons: [btn("Copy Install Command", #selector(copyFuseCommand), primary: true)], busy: false)
        } else if let v = v {
            let icon = v.roMountPoint.map { NSWorkspace.shared.icon(forFile: $0) } ?? Self.driveIcon
            if busy {
                placeholder.set(icon: icon, title: v.displayName, detail: "Working…", buttons: [], busy: true)
            } else {
                let state = v.roMountPoint != nil ? "Mounted read-only by macOS" : "Not mounted"
                var buttons = [btn("Mount Read-Write", #selector(mountTapped), primary: true)]
                if v.roMountPoint != nil { buttons.append(btn("Open Read-Only", #selector(openReadOnly))) }
                buttons.append(btn("Discard Hibernation & Mount…", #selector(forceMountTapped)))
                placeholder.set(icon: icon, title: v.displayName,
                                detail: "\(state) · \(Fmt.bytes(v.sizeBytes))\n\nMount it read-write to create, rename, copy and delete files.",
                                buttons: buttons, busy: false)
            }
        } else {
            placeholder.set(icon: Self.driveIcon, title: "No NTFS Drives",
                            detail: "Connect an NTFS-formatted drive. If it doesn’t appear, try another cable or port; some drives need their own power.",
                            buttons: [], busy: false)
        }
    }

    /// The system's external-drive icon (what Finder shows for USB disks).
    static let driveIcon: NSImage = NSImage(contentsOfFile: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns")
        ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage()

    @objc func mountTapped() { if let v = volume { model.onMount(v.id, false) } }
    @objc func forceMountTapped() { if let v = volume { model.onMount(v.id, true) } }
    @objc private func openReadOnly() { if let p = volume?.roMountPoint { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc private func copyFuseCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install --cask macos-fuse-t/cask/fuse-t", forType: .string)
    }

    // MARK: Loading & display

    /// Re-reads the current folder from disk, keeping expanded folders and the selection.
    func reload(select: [URL]? = nil) {
        guard isViewLoaded else { return }
        if outline.currentEditor() != nil { return }   // don't yank the list away mid-rename
        let keepSelection = select ?? selectedNodes.map(\.url)
        let expanded = expandedURLs()
        allNodes = dir.map { sort.sort(FileNode.list($0)) } ?? []
        freeSpace = (try? root?.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        redisplay(select: keepSelection, expanded: expanded)
        updatePath()
    }

    private func redisplay(select: [URL], expanded: Set<URL>) {
        nodes = filter.isEmpty ? allNodes : allNodes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        outline.reloadData()
        func expand(_ list: [FileNode]) {
            for n in list where n.isFolder && expanded.contains(n.url) { outline.expandItem(n); expand(kids(n)) }
        }
        expand(nodes)
        collection.selectionIndexPaths = []
        collection.reloadData()
        selectURLs(select)
        selectionChanged()
    }

    private func expandedURLs() -> Set<URL> {
        var s = Set<URL>()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? FileNode, outline.isItemExpanded(n) { s.insert(n.url) }
        }
        return s
    }

    private func selectURLs(_ urls: [URL]) {
        let want = Set(urls.map(\.standardizedFileURL))
        var rows = IndexSet()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? FileNode, want.contains(n.url.standardizedFileURL) { rows.insert(r) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
        let ips = Set(nodes.indices.filter { want.contains(nodes[$0].url.standardizedFileURL) }.map { IndexPath(item: $0, section: 0) })
        collection.selectionIndexPaths = ips
        if let first = ips.min() { collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
    }

    private func kids(_ n: FileNode) -> [FileNode] {
        if let c = n.children { return c }
        let c = sort.sort(FileNode.list(n.url)); n.children = c; return c
    }

    private func resort(_ list: [FileNode]) -> [FileNode] {
        for n in list { if let c = n.children { n.children = resort(c) } }
        return sort.sort(list)
    }

    func setFilter(_ s: String) {
        guard s != filter else { return }
        filter = s
        redisplay(select: selectedNodes.map(\.url), expanded: expandedURLs())
    }

    func setMode(_ m: ViewMode) {
        guard m != mode else { return }
        let sel = selectedNodes.map(\.url)
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "viewMode")
        applyMode()
        selectURLs(sel)
        view.window?.makeFirstResponder(activeView)
        onStateChange()
    }

    private func applyMode() {
        updatePlaceholder()
    }

    func focusFiles() { if isMounted { view.window?.makeFirstResponder(activeView) } }

    private func updatePath() {
        guard let root = root, let dir = dir else { pathControl.pathItems = []; pathURLs = []; return }
        let rel = dir.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
            .split(separator: "/").map(String.init)
        pathURLs = [root]
        for c in rel { pathURLs.append(pathURLs.last!.appendingPathComponent(c)) }
        pathControl.pathItems = pathURLs.enumerated().map { i, u in
            let item = NSPathControlItem()
            item.title = i == 0 ? (volume?.displayName ?? u.lastPathComponent) : u.lastPathComponent
            let img = NSWorkspace.shared.icon(forFile: u.path); img.size = NSSize(width: 16, height: 16)
            item.image = img
            return item
        }
    }

    @objc private func pathClicked() {
        guard let item = pathControl.clickedPathItem,
              let i = pathControl.pathItems.firstIndex(where: { $0 === item }), i < pathURLs.count else { return }
        navigate(to: pathURLs[i])
    }

    func selectionChanged() {
        updateStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        onStateChange()
    }

    private func updateStatus() {
        if let a = activity ?? (busy && isMounted ? "Working…" : nil) {
            statusLabel.stringValue = a; statusSpinner.startAnimation(nil); return
        }
        statusSpinner.stopAnimation(nil)
        guard isMounted else {
            statusLabel.stringValue = volume.map { "\($0.displayName) — \(Fmt.bytes($0.sizeBytes))" } ?? ""
            return
        }
        let sel = selectedNodes.count
        var s = sel > 0 ? "\(sel) of \(Fmt.items(nodes.count)) selected" : Fmt.items(nodes.count)
        if let f = freeSpace { s += ", \(Fmt.bytes(f)) available" }
        if !filter.isEmpty { s += " — matching “\(filter)”" }
        statusLabel.stringValue = s
    }

    private func setActivity(_ a: String?) { activity = a; updateStatus() }

    // MARK: Navigation

    func navigate(to url: URL, select: URL? = nil) {
        guard isMounted, url.standardizedFileURL != dir?.standardizedFileURL else { return }
        if let d = dir { back.append(d) }
        forward.removeAll()
        go(url, select: select)
    }

    private func go(_ url: URL, select: URL?) {
        dir = url
        if !filter.isEmpty { filter = "" }
        reload(select: select.map { [$0] } ?? [])
        if mode == .list { outline.scrollRowToVisible(max(outline.selectedRow, 0)) }
        else { iconScroll.contentView.scroll(to: .zero) }
        onStateChange()
    }

    func goBack() {
        guard let u = back.popLast() else { return }
        if let d = dir { forward.append(d) }
        go(u, select: dir)
    }
    func goForward() {
        guard let u = forward.popLast() else { return }
        if let d = dir { back.append(d) }
        go(u, select: nil)
    }
    func goEnclosing() {
        guard let d = dir, !atRoot else { return }
        navigate(to: d.deletingLastPathComponent(), select: d)
    }

    // MARK: Opening

    func openSelection() { open(selectedNodes) }
    func openItem(at i: Int) { if i < nodes.count { open([nodes[i]]) } }

    private func open(_ list: [FileNode]) {
        let files = list.filter { !$0.isFolder }
        for f in files { NSWorkspace.shared.open(f.url) }
        if files.isEmpty, let folder = list.first { navigate(to: folder.url) }
    }

    @objc private func listDoubleClicked() {
        let r = outline.clickedRow
        if r >= 0, let n = outline.item(atRow: r) as? FileNode { open([n]) }
    }

    func revealInFinder() {
        let urls = selectedNodes.map(\.url)
        if urls.isEmpty, let d = dir { NSWorkspace.shared.open(d) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: File operations

    func newFolder() {
        guard let d = dir else { return }
        let url = Self.unique("untitled folder", in: d)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            reload(select: [url])
            renameSelection()
        } catch { present(error) }
    }

    func renameSelection() {
        let sel = selectedNodes
        guard sel.count == 1, let n = sel.first else { return }
        switch mode {
        case .list:
            let row = outline.row(forItem: n)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell,
                  let tf = cell.textField else { return }
            outline.scrollRowToVisible(row)
            renameOriginal = n.name
            tf.isEditable = true; tf.delegate = self
            view.window?.makeFirstResponder(tf)
            // Like Finder: select the name without its extension.
            let base = n.isFolder ? n.name : (n.name as NSString).deletingPathExtension
            tf.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        case .icons:
            guard let w = view.window else { return }
            let a = NSAlert()
            a.messageText = "Rename “\(n.name)”"
            a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
            let tf = NSTextField(string: n.name); tf.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            a.accessoryView = tf
            a.window.initialFirstResponder = tf
            a.beginSheetModal(for: w) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.rename(n, to: tf.stringValue) }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)), let o = renameOriginal {
            (control as? NSTextField)?.stringValue = o
            view.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let tf = note.object as? NSTextField else { return }
        tf.isEditable = false; tf.delegate = nil
        renameOriginal = nil
        let row = outline.row(for: tf)
        guard row >= 0, let n = outline.item(atRow: row) as? FileNode else { return }
        let newName = tf.stringValue
        DispatchQueue.main.async { [weak self] in
            self?.rename(n, to: newName)
            self?.view.window?.makeFirstResponder(self?.outline)
        }
    }

    private func rename(_ n: FileNode, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != n.name else { reload(); return }
        guard !name.contains("/"), !name.contains(":") else {
            present(message: "The name “\(name)” can’t be used.", info: "Try using a name without “/” or “:”.")
            reload(); return
        }
        let dest = n.url.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path), dest.path.lowercased() != n.url.path.lowercased() {
            present(message: "The name “\(name)” is already taken.", info: "Please choose a different name.")
            reload(); return
        }
        do { try FileManager.default.moveItem(at: n.url, to: dest); reload(select: [dest]) }
        catch { present(error); reload() }
    }

    func deleteSelection() {
        let urls = selectedNodes.map(\.url)
        guard !urls.isEmpty, let w = view.window else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = urls.count == 1 ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
                                        : "Are you sure you want to delete these \(urls.count) items?"
        a.informativeText = "NTFS drives have no Trash, so \(urls.count == 1 ? "this item" : "these items") will be deleted immediately. You can’t undo this action."
        let del = a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        del.hasDestructiveAction = true
        del.keyEquivalent = ""; a.buttons[1].keyEquivalent = "\r"   // Return = Cancel, so a stray Return is safe
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self = self else { return }
            var failed: Error?
            for u in urls { do { try FileManager.default.removeItem(at: u) } catch { failed = error } }
            self.reload(select: [])
            if let e = failed { self.present(e) }
        }
    }

    func copySelection() {
        let urls = selectedNodes.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    var canPaste: Bool { isMounted && !Self.fileURLs(NSPasteboard.general).isEmpty }

    func paste() {
        guard let d = dir else { return }
        transfer(Self.fileURLs(NSPasteboard.general), to: d, move: false)
    }

    func duplicateSelection() {
        let sel = selectedNodes.map(\.url)
        guard !sel.isEmpty else { return }
        runInBackground("Duplicating \(Fmt.items(sel.count))…", sel) { src in
            let ns = src.lastPathComponent as NSString
            let ext = ns.pathExtension
            let dest = Self.unique(ns.deletingPathExtension + " copy" + (ext.isEmpty ? "" : "." + ext),
                                   in: src.deletingLastPathComponent())
            try FileManager.default.copyItem(at: src, to: dest)
            return dest
        }
    }

    /// Copies (or, for drags inside this drive, moves) files into `target`.
    func transfer(_ urls: [URL], to target: URL, move: Bool) {
        let t = target.standardizedFileURL
        let srcs = urls.filter { !(move && $0.deletingLastPathComponent().standardizedFileURL == t) }
        guard !srcs.isEmpty else { return }
        runInBackground("\(move ? "Moving" : "Copying") \(Fmt.items(srcs.count))…", srcs) { src in
            let dest = Self.unique(src.lastPathComponent, in: target)
            if move { try FileManager.default.moveItem(at: src, to: dest) } else { try FileManager.default.copyItem(at: src, to: dest) }
            return dest
        }
    }

    private func runInBackground(_ label: String, _ srcs: [URL], _ op: @escaping (URL) throws -> URL) {
        setActivity(label)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [URL] = [], failures: [String] = []
            for s in srcs {
                do { done.append(try op(s)) } catch { failures.append("“\(s.lastPathComponent)”: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.setActivity(nil)
                self.reload(select: done)
                if !failures.isEmpty {
                    self.present(message: "Some items couldn’t be copied.", info: failures.joined(separator: "\n"))
                }
            }
        }
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// "name", then "name 2", "name 3", … keeping the extension ("x copy" becomes "x copy 2").
    static func unique(_ name: String, in dir: URL) -> URL {
        var dest = dir.appendingPathComponent(name)
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext)); n += 1
        }
        return dest
    }

    private func present(_ error: Error) {
        guard let w = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: w)
    }
    private func present(message: String, info: String) {
        guard let w = view.window else { return }
        let a = NSAlert(); a.messageText = message; a.informativeText = info
        a.beginSheetModal(for: w)
    }

    // MARK: Context menu

    func contextMenu() -> NSMenu? {
        guard isMounted else { return nil }
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector) { m.addItem(withTitle: t, action: sel, keyEquivalent: "") }
        let sel = selectedNodes
        if sel.isEmpty {
            add("New Folder", #selector(MainWindowController.newFolder(_:)))
            m.addItem(.separator())
            add("Paste", #selector(MainWindowController.paste(_:)))
            m.addItem(.separator())
            add("Show in Finder", #selector(MainWindowController.revealInFinder(_:)))
        } else {
            add("Open", #selector(MainWindowController.openItems(_:)))
            m.addItem(.separator())
            add(sel.count == 1 ? "Delete Immediately…" : "Delete \(sel.count) Items Immediately…", #selector(MainWindowController.deleteItems(_:)))
            m.addItem(.separator())
            if sel.count == 1 { add("Rename", #selector(MainWindowController.rename(_:))) }
            add("Duplicate", #selector(MainWindowController.duplicate(_:)))
            add("Quick Look", #selector(MainWindowController.quickLook(_:)))
            m.addItem(.separator())
            add(sel.count == 1 ? "Copy “\(sel[0].name)”" : "Copy \(sel.count) Items", #selector(MainWindowController.copy(_:)))
            add("Paste", #selector(MainWindowController.paste(_:)))
            m.addItem(.separator())
            add("Show in Finder", #selector(MainWindowController.revealInFinder(_:)))
        }
        return m
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let p = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), p.isVisible { p.orderOut(nil); return }
        guard !selectedNodes.isEmpty else { return }
        view.window?.makeFirstResponder(activeView)
        p.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedNodes.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let s = selectedNodes
        return index < s.count ? s[index].url as NSURL : nil
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the selection, like Finder.
        guard event.type == .keyDown else { return false }
        activeView.keyDown(with: event); return true
    }

    // MARK: List view data source / delegate

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? FileNode else { return nodes.count }
        return kids(n).count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FileNode else { return nodes[index] }
        return kids(n)[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isFolder ?? false }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let id = col?.identifier.rawValue ?? "name"
        if id == "name" {
            let c = ov.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
            c.imageView?.image = n.icon
            c.textField?.stringValue = n.name
            c.textField?.isEditable = false
            return c
        }
        let c = ov.makeView(withIdentifier: TextCell.id, owner: nil) as? TextCell ?? TextCell()
        let tf = c.textField!
        switch id {
        case "date": tf.stringValue = n.modified.map { Fmt.date.string(from: $0) } ?? "--"; tf.alignment = .left
        case "size": tf.stringValue = n.isFolder ? "--" : Fmt.bytes(n.size); tf.alignment = .right
        default: tf.stringValue = n.kind; tf.alignment = .left
        }
        return c
    }

    func outlineView(_ ov: NSOutlineView, typeSelectStringFor col: NSTableColumn?, item: Any) -> String? {
        col?.identifier.rawValue == "name" ? (item as? FileNode)?.name : nil
    }

    func outlineViewSelectionDidChange(_ n: Notification) { selectionChanged() }

    func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = ov.sortDescriptors.first, let k = d.key else { return }
        sort = FileSort(key: k, ascending: d.ascending)
        let sel = selectedNodes.map(\.url), exp = expandedURLs()
        allNodes = resort(allNodes)
        redisplay(select: sel, expanded: exp)
    }

    // Drag out (to Finder or another folder here)
    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    // Drop in: onto a folder row → into that folder; anywhere else → the current folder.
    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let n = item as? FileNode, n.isFolder {
            ov.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return dragOperation(info, into: n.url)
        }
        ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return dragOperation(info, into: dir)
    }
    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        acceptDrop(info, into: (item as? FileNode)?.url ?? dir)
    }

    // MARK: Icon view data source / delegate

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { nodes.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: IconItem.id, for: ip)
        (item as? IconItem)?.configure(nodes[ip.item])
        return item
    }
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { selectionChanged() }

    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        ip.item < nodes.count ? nodes[ip.item].url as NSURL : nil
    }
    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let i = ip.pointee.item
        if op.pointee == .on, i < nodes.count, nodes[i].isFolder { return dragOperation(info, into: nodes[i].url) }
        op.pointee = .before
        return dragOperation(info, into: dir)
    }
    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let target = (op == .on && ip.item < nodes.count && nodes[ip.item].isFolder) ? nodes[ip.item].url : dir
        return acceptDrop(info, into: target)
    }

    // MARK: Drag & drop helpers

    private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
        let src = info.draggingSource as? NSView
        return src === outline || src === collection
    }

    private func dragOperation(_ info: NSDraggingInfo, into target: URL?) -> NSDragOperation {
        guard let target = target, isMounted else { return [] }
        let urls = Self.fileURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        // Never drop a folder into itself or one of its own subfolders.
        let t = target.standardizedFileURL.path
        if urls.contains(where: { let p = $0.standardizedFileURL.path; return t == p || t.hasPrefix(p + "/") }) { return [] }
        return isInternalDrag(info) ? .move : .copy
    }

    private func acceptDrop(_ info: NSDraggingInfo, into target: URL?) -> Bool {
        guard let target = target else { return false }
        let urls = Self.fileURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        transfer(urls, to: target, move: isInternalDrag(info))
        return true
    }
}
