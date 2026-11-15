import AppKit
import Quartz

// MARK: - Model

/// One file or folder on the mounted drive. Folder contents load lazily (when expanded in list view).
final class FileNode {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey,
                                         .contentModificationDateKey, .localizedTypeDescriptionKey]
    let url: URL
    let isDir: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date?
    let kind: String
    var children: [FileNode]?
    private var cachedIcon: NSImage?

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: Set(Self.keys))
        isDir = v?.isDirectory ?? false
        isPackage = v?.isPackage ?? false
        size = Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
        modified = v?.contentModificationDate
        kind = v?.localizedTypeDescription ?? (isDir ? "Folder" : "Document")
    }

    var name: String { url.lastPathComponent }
    /// A folder you navigate into (packages such as .app open instead, like in Finder).
    var isFolder: Bool { isDir && !isPackage }
    var icon: NSImage {
        if let i = cachedIcon { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path); cachedIcon = i; return i
    }

    static func list(_ dir: URL) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.map(FileNode.init)
    }
}

struct FileSort {
    var key = "name"
    var ascending = true

    /// Folders stay on top (Finder's "Keep folders on top"); ties fall back to natural name order.
    func sort(_ a: [FileNode]) -> [FileNode] {
        a.sorted { x, y in
            if x.isFolder != y.isFolder { return x.isFolder }
            var r: ComparisonResult
            switch key {
            case "date": r = (x.modified ?? .distantPast).compare(y.modified ?? .distantPast)
            case "size": r = x.size == y.size ? .orderedSame : (x.size < y.size ? .orderedAscending : .orderedDescending)
            case "kind": r = x.kind.localizedStandardCompare(y.kind)
            default: r = .orderedSame
            }
            if r == .orderedSame { r = x.name.localizedStandardCompare(y.name) }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func items(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s")" }
}

// MARK: - Finder-style key handling shared by list and icon views

private func handleFinderKey(_ e: NSEvent, _ b: BrowserController?) -> Bool {
    guard let b = b else { return false }
    guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
    switch e.keyCode {
    case 36, 76: b.renameSelection(); return true        // Return / Enter: rename
    case 49: b.toggleQuickLook(); return true            // Space: Quick Look
    case 51, 117: b.deleteSelection(); return true       // Delete / Forward Delete
    default: return false
    }
}

final class FileOutlineView: NSOutlineView {
    weak var browser: BrowserController?

    override func keyDown(with e: NSEvent) { if !handleFinderKey(e, browser) { super.keyDown(with: e) } }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Like Finder: right-clicking an unselected row selects it; empty space clears the selection.
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 { deselectAll(nil) }
        else if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return browser?.contextMenu()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = browser; panel.delegate = browser }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

final class FileCollectionView: NSCollectionView {
    weak var browser: BrowserController?

    override func keyDown(with e: NSEvent) { if !handleFinderKey(e, browser) { super.keyDown(with: e) } }

    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        if e.clickCount == 2, let ip = indexPathForItem(at: convert(e.locationInWindow, from: nil)) {
            browser?.openItem(at: ip.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(ip) { selectionIndexPaths = [ip] }
        } else {
            selectionIndexPaths = []
        }
        browser?.selectionChanged()
        return browser?.contextMenu()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = browser; panel.delegate = browser }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

// MARK: - Cells

final class NameCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NameCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        let iv = NSImageView(); iv.imageScaling = .scaleProportionallyUpOrDown
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.cell?.usesSingleLineMode = true
        for v in [iv, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = iv; textField = tf
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class TextCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TextCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.textColor = .secondaryLabelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = tf
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Icon-view item: large icon with a rounded gray highlight and an accent-colored name label when selected.
final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconItem")
    private let iconBG = NSBox(), labelBG = NSBox()

    override func loadView() {
        let v = NSView()
        let iv = NSImageView(); iv.imageScaling = .scaleProportionallyUpOrDown
        let tf = NSTextField(wrappingLabelWithString: "")
        tf.alignment = .center
        tf.font = .systemFont(ofSize: 12)
        tf.maximumNumberOfLines = 2
        tf.cell?.truncatesLastVisibleLine = true
        tf.preferredMaxLayoutWidth = 92
        for b in [iconBG, labelBG] {
            b.boxType = .custom; b.borderWidth = 0; b.titlePosition = .noTitle; b.isHidden = true
        }
        iconBG.cornerRadius = 6; iconBG.fillColor = .unemphasizedSelectedContentBackgroundColor
        labelBG.cornerRadius = 4; labelBG.fillColor = .selectedContentBackgroundColor
        for s in [iconBG, labelBG, iv, tf] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 64), iv.heightAnchor.constraint(equalToConstant: 64),
            iconBG.centerXAnchor.constraint(equalTo: iv.centerXAnchor), iconBG.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
            iconBG.widthAnchor.constraint(equalToConstant: 74), iconBG.heightAnchor.constraint(equalToConstant: 74),
            tf.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 7),
            tf.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            tf.widthAnchor.constraint(lessThanOrEqualToConstant: 92),
            labelBG.leadingAnchor.constraint(equalTo: tf.leadingAnchor, constant: -3),
            labelBG.trailingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 3),
            labelBG.topAnchor.constraint(equalTo: tf.topAnchor, constant: -1),
            labelBG.bottomAnchor.constraint(equalTo: tf.bottomAnchor, constant: 1),
        ])
        view = v; imageView = iv; textField = tf
    }

    func configure(_ n: FileNode) {
        imageView?.image = n.icon
        textField?.stringValue = n.name
        textField?.toolTip = n.name
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        iconBG.isHidden = !isSelected; labelBG.isHidden = !isSelected
        textField?.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
    }
}

// MARK: - Placeholder (no drive / not mounted / FUSE-T missing)

final class PlaceholderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        detail.alignment = .center; detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 400
        spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [icon, title, detail, spinner, buttons])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.setCustomSpacing(16, after: icon); stack.setCustomSpacing(18, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { NSColor.textBackgroundColor.setFill(); dirtyRect.fill() }

    func set(icon img: NSImage?, title t: String, detail d: String, buttons bs: [NSButton], busy: Bool) {
        icon.image = img
        title.stringValue = t
        detail.stringValue = d
        buttons.setViews(bs, in: .center)
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }
}
