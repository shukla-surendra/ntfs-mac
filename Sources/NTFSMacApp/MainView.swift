import AppKit
import NTFSKit

/// Shared state between the AppDelegate (privileged CLI work) and the window.
final class AppModel {
    var volumes: [NTFSVolume] = [] { didSet { onChange() } }
    var busy = Set<String>() { didSet { onChange() } }
    var fuseInstalled = true
    var onChange: () -> Void = {}
    var onMount: (String, Bool) -> Void = { _, _ in }
    var onUnmount: (String, Bool) -> Void = { _, _ in }
}

final class FileTable: NSTableView {
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onDelete: () -> Void = {}
    @objc func copy(_ sender: Any?) { onCopy() }
    @objc func paste(_ sender: Any?) { onPaste() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { onDelete() } else { super.keyDown(with: e) }
    }
}

struct FileItem { let url: URL; let isDir: Bool; let size: Int64; let modified: Date? }

final class MainWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let model: AppModel
    private let drivePopup = NSPopUpButton()
    private let driveStatus = NSTextField(labelWithString: "")
    private let mountBtn = NSButton(title: "Mount Read-Write", target: nil, action: nil)
    private let forceBtn = NSButton(title: "Mount + discard hibernation…", target: nil, action: nil)
    private let unmountBtn = NSButton(title: "Unmount", target: nil, action: nil)
    private let ejectBtn = NSButton(title: "Eject", target: nil, action: nil)
    private let upBtn = NSButton(title: "↑ Up", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let copyBtn = NSButton(title: "Copy", target: nil, action: nil)
    private let pasteBtn = NSButton(title: "Paste", target: nil, action: nil)
    private let folderBtn = NSButton(title: "New Folder", target: nil, action: nil)
    private let deleteBtn = NSButton(title: "Delete", target: nil, action: nil)
    private let finderBtn = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let table = FileTable()
    private let spinner = NSProgressIndicator()

    private var items: [FileItem] = []
    private var root: URL?
    private var dir: URL?
    private var selectedID: String?

    init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "NTFS Mac"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 400)
        window.delegate = self
        build()
        window.center()
        model.onChange = { [weak self] in self?.syncVolumes() }
    }

    private func button(_ b: NSButton, _ sel: Selector) -> NSButton {
        b.target = self; b.action = sel; b.bezelStyle = .rounded; return b
    }

    private func build() {
        drivePopup.target = self; drivePopup.action = #selector(driveChanged)
        let row1 = NSStackView(views: [NSTextField(labelWithString: "Drive:"), drivePopup, driveStatus,
                                       NSView(), button(mountBtn, #selector(mountTapped)), button(forceBtn, #selector(forceTapped)),
                                       button(unmountBtn, #selector(unmountTapped)), button(ejectBtn, #selector(ejectTapped))])
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let row2 = NSStackView(views: [button(upBtn, #selector(upTapped)), pathLabel, spinner,
                                       button(copyBtn, #selector(copyTapped)), button(pasteBtn, #selector(pasteTapped)),
                                       button(folderBtn, #selector(newFolderTapped)), button(deleteBtn, #selector(deleteTapped)),
                                       button(finderBtn, #selector(finderTapped))])
        for r in [row1, row2] { r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY }

        for (id, title, w) in [("name", "Name", 420.0), ("size", "Size", 90.0), ("date", "Modified", 150.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = w
            c.resizingMask = id == "name" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.target = self; table.doubleAction = #selector(rowDoubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onCopy = { [weak self] in self?.copyTapped() }
        table.onPaste = { [weak self] in self?.pasteTapped() }
        table.onDelete = { [weak self] in self?.deleteTapped() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true

        emptyLabel.alignment = .center; emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [row1, row2, scroll, emptyLabel, message])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        let content = window.contentView!
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            row1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            row2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        syncVolumes()
    }

    // MARK: Drives

    private var current: NTFSVolume? { model.volumes.first { $0.id == selectedID } }

    func syncVolumes() {
        let vols = model.volumes
        if selectedID == nil || !vols.contains(where: { $0.id == selectedID }) { selectedID = vols.first?.id }
        drivePopup.removeAllItems()
        for v in vols { drivePopup.addItem(withTitle: "\(v.displayName) (\(v.id))") }
        if let i = vols.firstIndex(where: { $0.id == selectedID }) { drivePopup.selectItem(at: i) }

        let v = current
        let busy = v.map { model.busy.contains($0.id) } ?? false
        let rw = v?.rwMountPoint
        let newRoot = rw.map { URL(fileURLWithPath: $0) }
        if newRoot != root { root = newRoot; dir = newRoot; reload() }

        if let v = v {
            let size = ByteCountFormatter.string(fromByteCount: v.sizeBytes, countStyle: .file)
            driveStatus.stringValue = busy ? "working…" : "\(size) — " + (rw != nil ? "read-write" : (v.roMountPoint != nil ? "read-only" : "not mounted"))
        } else { driveStatus.stringValue = "" }
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)

        mountBtn.isEnabled = v != nil && rw == nil && !busy
        forceBtn.isEnabled = mountBtn.isEnabled
        unmountBtn.isEnabled = rw != nil && !busy
        ejectBtn.isEnabled = v != nil && !busy && rw != nil
        for b in [mountBtn, forceBtn] { b.isHidden = rw != nil }
        for b in [unmountBtn, ejectBtn, upBtn, copyBtn, pasteBtn, folderBtn, deleteBtn, finderBtn, pathLabel] { b.isHidden = rw == nil }

        if v == nil {
            emptyLabel.stringValue = model.fuseInstalled
                ? "No NTFS drives found.\n\nPlug the drive in. If it still doesn't appear, try another cable/port; some drives need their own power."
                : "FUSE-T is not installed.\nRun: brew install --cask macos-fuse-t/cask/fuse-t"
        } else if rw == nil {
            emptyLabel.stringValue = (v!.roMountPoint != nil ? "“\(v!.displayName)” is mounted read-only by macOS." : "“\(v!.displayName)” is not mounted.")
                + "\n\nClick “Mount Read-Write” to edit its files."
        }
        emptyLabel.isHidden = rw != nil
        table.enclosingScrollView?.isHidden = rw == nil
    }

    @objc private func driveChanged() {
        let i = drivePopup.indexOfSelectedItem
        if i >= 0, i < model.volumes.count { selectedID = model.volumes[i].id; root = nil; syncVolumes() }
    }
    @objc private func mountTapped() { if let v = current { model.onMount(v.id, false) } }
    @objc private func forceTapped() { if let v = current { model.onMount(v.id, true) } }
    @objc private func unmountTapped() { if let v = current { model.onUnmount(v.id, false) } }
    @objc private func ejectTapped() { if let v = current { model.onUnmount(v.id, true) } }

    // MARK: Files

    private func reload() {
        guard let dir = dir else { items = []; table.reloadData(); return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate)
        }.sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
        }
        table.reloadData()
        let rel = dir.standardizedFileURL.path.replacingOccurrences(of: root?.standardizedFileURL.path ?? "", with: "")
        pathLabel.stringValue = (current?.displayName ?? "") + (rel.isEmpty ? "/" : rel)
        upBtn.isEnabled = !rel.isEmpty
    }

    @objc private func upTapped() { if let d = dir, d.standardizedFileURL != root?.standardizedFileURL { dir = d.deletingLastPathComponent(); reload() } }
    @objc private func finderTapped() { if let d = dir { NSWorkspace.shared.open(d) } }
    @objc private func rowDoubleClicked() {
        let r = table.clickedRow; guard r >= 0, r < items.count else { return }
        if items[r].isDir { dir = items[r].url; reload() } else { NSWorkspace.shared.open(items[r].url) }
    }

    private var selectedURLs: [URL] { table.selectedRowIndexes.map { items[$0].url } }

    @objc private func copyTapped() {
        let urls = selectedURLs; guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        message.stringValue = "Copied \(urls.count) item(s). Open the destination folder and click Paste."
    }
    @objc private func pasteTapped() { paste(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []) }

    private func paste(_ urls: [URL]) {
        guard let target = dir else { return }
        guard !urls.isEmpty else { message.stringValue = "Nothing to paste. Copy files here or in Finder first."; return }
        spinner.startAnimation(nil); message.stringValue = "Copying…"
        DispatchQueue.global().async {
            var failures: [String] = []
            for src in urls {
                do { try FileManager.default.copyItem(at: src, to: Self.unique(src.lastPathComponent, in: target)) }
                catch { failures.append("\(src.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.spinner.stopAnimation(nil)
                self.message.stringValue = failures.isEmpty ? "Pasted \(urls.count) item(s)." : "Failed: " + failures.joined(separator: "; ")
                self.reload()
            }
        }
    }

    private static func unique(_ name: String, in dir: URL) -> URL {
        var dest = dir.appendingPathComponent(name); var n = 2
        let ns = name as NSString; let base = ns.deletingPathExtension, ext = ns.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(base + " \(n)" + (ext.isEmpty ? "" : "." + ext)); n += 1
        }
        return dest
    }

    @objc private func newFolderTapped() {
        guard let d = dir else { return }
        do { try FileManager.default.createDirectory(at: Self.unique("untitled folder", in: d), withIntermediateDirectories: false); reload() }
        catch { message.stringValue = error.localizedDescription }
    }

    @objc private func deleteTapped() {
        let urls = selectedURLs; guard !urls.isEmpty else { return }
        let a = NSAlert(); a.messageText = "Permanently delete \(urls.count) item(s)?"
        a.informativeText = "There is no Trash on NTFS drives. This cannot be undone."
        a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Delete")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        for u in urls { do { try FileManager.default.removeItem(at: u) } catch { message.stringValue = error.localizedDescription } }
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let id = col?.identifier.rawValue ?? ""
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(tf); cell.textField = tf
        switch id {
        case "name":
            let img = NSImageView(image: NSWorkspace.shared.icon(forFile: item.url.path))
            img.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(img)
            tf.stringValue = item.url.lastPathComponent
            NSLayoutConstraint.activate([
                img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                img.widthAnchor.constraint(equalToConstant: 18), img.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6)])
        case "size":
            tf.stringValue = item.isDir ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            tf.textColor = .secondaryLabelColor
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        default:
            tf.stringValue = item.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
            tf.textColor = .secondaryLabelColor
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor).isActive = true
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        return cell
    }

    // Drag out to Finder
    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { items[row].url as NSURL }

    // Drop in from Finder
    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tv.setDropRow(-1, dropOperation: .on); return dir == nil ? [] : .copy
    }
    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        paste(urls); return !urls.isEmpty
    }
}
