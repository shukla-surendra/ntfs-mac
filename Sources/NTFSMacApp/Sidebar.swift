import AppKit
import NTFSKit

/// Finder-style source-list sidebar listing the connected NTFS drives.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: (String) -> Void = { _ in }
    var onEject: (String) -> Void = { _ in }
    var onToggleAutoMount: (Bool) -> Void = { _ in }

    /// Outline items need stable object identity, so each drive id maps to one Entry.
    private final class Entry { let id: String; init(_ id: String) { self.id = id } }
    private let header = Entry("")
    private var entries: [String: Entry] = [:]

    private let outline = NSOutlineView()
    private let autoBox = NSButton(checkboxWithTitle: "Mount drives automatically", target: nil, action: nil)
    private var volumes: [NTFSVolume] = []
    private var busy = Set<String>()
    private var suppressSelect = false
    private(set) var selectedID: String?

    override func loadView() {
        let v = NSView()
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self; outline.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true

        autoBox.controlSize = .small
        autoBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoBox.target = self; autoBox.action = #selector(autoToggled)
        autoBox.toolTip = "Installs a small background service: NTFS drives mount read-write as soon as they are plugged in, "
            + "and mounting/unmounting no longer asks for your password."

        for s in [scroll, autoBox] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: autoBox.topAnchor, constant: -8),
            autoBox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            autoBox.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            autoBox.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
        ])
        view = v
    }

    func update(volumes vols: [NTFSVolume], busy b: Set<String>, autoMount: Bool) {
        autoBox.state = autoMount ? .on : .off
        guard vols != volumes || b != busy || outline.numberOfRows == 0 else { return }
        volumes = vols; busy = b
        suppressSelect = true
        outline.reloadData()
        outline.expandItem(header)
        if let id = selectedID, let e = entries[id] {
            let row = outline.row(forItem: e)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        suppressSelect = false
    }

    func select(_ id: String?) {
        selectedID = id
        guard let id = id, let e = entries[id] else { outline.deselectAll(nil); return }
        let row = outline.row(forItem: e)
        suppressSelect = true
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        suppressSelect = false
    }

    private func entry(_ id: String) -> Entry {
        if let e = entries[id] { return e }
        let e = Entry(id); entries[id] = e; return e
    }

    @objc private func autoToggled() { onToggleAutoMount(autoBox.state == .on) }

    @objc private func ejectClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        if row >= 0, let e = outline.item(atRow: row) as? Entry { onEject(e.id) }
    }

    // MARK: Data source / delegate

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 1 : volumes.count }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? header : entry(volumes[index].id)
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Entry) === header }
    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Entry) === header }
    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Entry) !== header }
    func outlineView(_ ov: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let e = item as? Entry else { return nil }
        let cell = NSTableCellView()
        if e === header {
            let tf = NSTextField(labelWithString: "NTFS Drives")
            tf.font = .systemFont(ofSize: 11, weight: .semibold); tf.textColor = .secondaryLabelColor
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf); cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        guard let v = volumes.first(where: { $0.id == e.id }) else { return nil }
        let mounted = v.rwMountPoint != nil || v.roMountPoint != nil

        let iv = NSImageView(image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage())
        iv.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        iv.contentTintColor = v.rwMountPoint != nil ? .controlAccentColor : .secondaryLabelColor
        let tf = NSTextField(labelWithString: v.displayName)
        tf.lineBreakMode = .byTruncatingTail
        tf.textColor = mounted ? .labelColor : .secondaryLabelColor
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.imageView = iv; cell.textField = tf
        cell.toolTip = "\(v.displayName) — \(Fmt.bytes(v.sizeBytes)), "
            + (v.rwMountPoint != nil ? "read-write" : v.roMountPoint != nil ? "read-only (select to mount read-write)" : "not mounted")

        var views: [NSView] = [iv, tf, NSView()]
        if busy.contains(v.id) {
            let sp = NSProgressIndicator(); sp.style = .spinning; sp.controlSize = .small; sp.startAnimation(nil)
            views.append(sp)
        } else {
            if v.rwMountPoint == nil, v.roMountPoint != nil {
                let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Read-only") ?? NSImage())
                lock.symbolConfiguration = .init(pointSize: 10, weight: .regular)
                lock.contentTintColor = .tertiaryLabelColor
                views.append(lock)
            }
            if mounted {
                let b = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject") ?? NSImage(),
                                 target: self, action: #selector(ejectClicked(_:)))
                b.isBordered = false; b.contentTintColor = .secondaryLabelColor; b.toolTip = "Eject “\(v.displayName)”"
                b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
                views.append(b)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 18),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !suppressSelect, let e = outline.item(atRow: outline.selectedRow) as? Entry, e !== header else { return }
        selectedID = e.id
        onSelect(e.id)
    }
}
