import Cocoa

enum MonitorColors {
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static let background = hex(0x131417)

    static let groundAlpha: CGFloat = 0.84

    static let windowGround = hex(0x131417, groundAlpha)
    static let text = hex(0xB8BFC5)
    static let muted = hex(0x939DA9)

    static let highlight = hex(0x2A2A2A)

    static let head = hex(0x474747)
    static let failure = hex(0xE24A3A)
}

private enum MonitorText {
    static var isGerman: Bool { Locale.preferredLanguages.first?.hasPrefix("de") == true }
    static var notConnected: String { isGerman ? "Nicht verbunden" : "Not connected" }
    static var projectUnknown: String { isGerman ? "Projekt unbekannt" : "Project unknown" }
    static var footer: String {
        isGerman ? "Fertige Jobs kommen mit der nächsten Anfrage an." : "Finished jobs arrive with your next request."
    }
    static var cancelJob: String { isGerman ? "Job abbrechen" : "Cancel Job" }
    static var cancelAll: String { isGerman ? "Alle abbrechen" : "Cancel all" }
    static var saveAs: String { isGerman ? "Speichern unter…" : "Save as…" }
    static var remove: String { isGerman ? "Entfernen" : "Remove" }
    static var fileNotMade: String { isGerman ? "Die Datei konnte nicht erstellt werden." : "The file could not be made." }
    static var fileNotSaved: String { isGerman ? "Die Datei konnte nicht gespeichert werden." : "The file could not be saved." }
}

final class QueueMonitor: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    struct Row {
        var code: String
        var project: String

        var first: Bool
        var state: String
        var line1: String
        var line2: String?
        var open: Bool
        var cancellable: Bool
        var detail: String
        var thumb: String?

        var thumbKey: String?

        var run: Int?

        var saveable = false
        var video = false

        var filename: String?

        var tool = false

        var removable = false
    }

    private let socketPath: String
    private var window: NSWindow?
    private let table = NSTableView()
    private var footer: NSTextField?
    private var rows: [Row] = []
    private var images: [String: (hash: Int, image: NSImage)] = [:]
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var generation = 0
    private var viewer: NSWindow?
    private var viewerImage: NSImageView?

    private var viewing: (code: String, run: Int, state: String, asked: Date)?
    private var viewerAsking = false
    private var saves: [String: (destination: URL, directory: URL)] = [:]
    private var wanted = false
    private(set) var connected = false

    var onChange: (() -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }

    private static let openKey = "queueMonitorOpen"

    static var wasOpen: Bool { UserDefaults.standard.bool(forKey: openKey) }

    func show(activate: Bool = true) {
        UserDefaults.standard.set(true, forKey: Self.openKey)
        if window == nil { buildWindow() }
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFront(nil)
        }
        guard !wanted else { return }
        wanted = true
        generation += 1
        let mine = generation
        Thread.detachNewThread { [weak self] in self?.connectLoop(mine) }
        onChange?()
    }

    func toggle() {
        if isOpen {
            UserDefaults.standard.set(false, forKey: Self.openKey)
            window?.close()
        } else {
            show()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {

        if sender === viewer {
            viewing = nil
            return true
        }
        UserDefaults.standard.set(false, forKey: Self.openKey)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === viewer { return }
        viewing = nil
        viewer?.close()
        disconnect()
        rows = []
        table.reloadData()
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    func disconnect() {
        wanted = false
        generation += 1
        lock.lock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
        lock.unlock()
        connected = false
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)

        window.title = MonitorText.notConnected
        window.subtitle = ""
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)

        window.isOpaque = MonitorColors.groundAlpha >= 1
        window.backgroundColor = MonitorColors.windowGround
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 250, height: 160)

        let remembered = UserDefaults.standard.string(forKey: "NSWindow Frame QueueMonitor") != nil
        window.setFrameAutosaveName("QueueMonitor")
        if !remembered, let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameTopLeftPoint(
                NSPoint(x: area.maxX - window.frame.width - 20, y: area.maxY - 20))
        }
        window.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil

        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: MonitorText.footer)
        self.footer = footer
        footer.font = NSFont.systemFont(ofSize: 10)
        footer.textColor = MonitorColors.muted
        footer.isHidden = true

        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 2
        footer.alignment = .center
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window.contentView = content
        self.window = window
    }

    private func connectLoop(_ mine: Int) {
        while wanted && generation == mine {
            let socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = socketPath.withCString { strncpy(destination, $0, capacity - 1) }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                close(socketFd)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            var on: Int32 = 1
            setsockopt(socketFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            fd = socketFd
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == mine else { return }
                self.connected = true

                self.window?.title = ""
                self.window?.subtitle = ""
                self.onChange?()
            }
            read(socketFd, mine)
            lock.lock()
            if fd == socketFd {
                close(socketFd)
                fd = -1
            }
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == mine else { return }
                self.connected = false
                self.window?.title = MonitorText.notConnected
                self.window?.subtitle = ""
                self.apply([])
                self.onChange?()
            }
            if wanted && generation == mine { Thread.sleep(forTimeInterval: 1) }
        }
    }

    private func read(_ socketFd: Int32, _ mine: Int) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while wanted && generation == mine {
            let n = Darwin.read(socketFd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)

                autoreleasepool {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.generation == mine else { return }
                        self.handle(object)
                    }
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock()
        let target = fd
        lock.unlock()
        guard target >= 0 else { return }
        _ = data.withUnsafeBytes { write(target, $0.baseAddress, $0.count) }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "state":
            let jobs = message["jobs"] as? [[String: Any]] ?? []
            let list = jobs.map { job in
                Row(
                    code: job["code"] as? String ?? "?", project: job["project"] as? String ?? "",
                    first: job["first"] as? Bool ?? true,
                    state: job["state"] as? String ?? "",
                    line1: job["line1"] as? String ?? "", line2: job["line2"] as? String,
                    open: job["open"] as? Bool ?? false,
                    cancellable: job["cancellable"] as? Bool ?? false,
                    detail: job["detail"] as? String ?? "", thumb: job["thumb"] as? String,
                    thumbKey: (job["thumb"] as? String).map { "\($0.utf8.count):\($0.hashValue)" },
                    run: job["run"] as? Int, saveable: job["saveable"] as? Bool ?? false,
                    video: job["video"] as? Bool ?? false, filename: job["filename"] as? String,
                    tool: job["tool"] as? Bool ?? false, removable: job["removable"] as? Bool ?? false)
            }
            if let project = message["project"] as? String {

                window?.title = project
                window?.subtitle = ""
            } else {

                window?.title = Self.drawThingsIsOpen ? MonitorText.projectUnknown : "gRPC Monitor"
                window?.subtitle = ""
            }
            apply(list)
        case "event":

            if message["kind"] as? String == "accepted", message["sound"] as? Bool ?? true {
              NSSound(named: NSSound.Name("Blow"))?.play()
            }
        case "preview":
            showBigPicture(message)
        case "saved":
            finishSave(message)
        default:
            break
        }
    }

    static var drawThingsIsOpen: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.liuliu.draw-things").isEmpty
    }

    private func apply(_ list: [Row]) {
        let sameJobs = list.map { $0.code + $0.state + ($0.first ? "1" : "0") } == rows.map { $0.code + $0.state + ($0.first ? "1" : "0") }
        rows = list

        footer?.isHidden = !list.contains { ["pending", "running", "generated"].contains($0.state) }
        let live = Set(list.compactMap { $0.thumbKey })
        images = images.filter { live.contains($0.key) }
        if sameJobs {
            for (index, row) in list.enumerated() {
                (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MonitorRowView)?
                    .update(row, image: image(for: row), separator: row.first && index > 0)
            }
        } else {
            table.reloadData()
        }
        refreshViewer()
    }

    private static let appIcons: [Bool: NSImage?] = {
        let drawThings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.liuliu.draw-things")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        var own = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if own == nil { own = NSApp.applicationIconImage }
        return [false: drawThings, true: own.map { QueueMonitor.exactIcon($0) }]
    }()

    static func exactIcon(_ icon: NSImage, slot: CGFloat = 48, inner: CGFloat = 41) -> NSImage {
        let largest = icon.representations.max { $0.pixelsWide < $1.pixelsWide }
        var source: CGImage?
        if let largest = largest {
            var rect = NSRect(x: 0, y: 0, width: largest.pixelsWide, height: largest.pixelsHigh)
            source = largest.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        if source == nil {
            var rect = NSRect(origin: .zero, size: NSSize(width: 1024, height: 1024))
            source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let original = source else { return icon }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        func resample(_ image: CGImage, to side: Int) -> CGImage? {
            var current = image

            while current.width >= 2 * side {
                let half = max(current.width / 2, side)
                guard let next = draw(current, side: half, into: half, at: 0) else { return nil }
                current = next
            }
            return current.width == side ? current : draw(current, side: side, into: side, at: 0)
        }
        func draw(_ image: CGImage, side: Int, into canvas: Int, at offset: Int) -> CGImage? {
            guard
                let ctx = CGContext(
                    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: offset, y: offset, width: side, height: side))
            return ctx.makeImage()
        }
        let result = NSImage(size: NSSize(width: slot, height: slot))
        for scale in [1, 2] {
            let canvas = Int(slot) * scale
            let side = Int((inner * CGFloat(scale)).rounded())
            let offset = (canvas - side) / 2
            guard let small = resample(original, to: side), let framed = draw(small, side: side, into: canvas, at: offset)
            else { continue }
            let rep = NSBitmapImageRep(cgImage: framed)
            rep.size = NSSize(width: slot, height: slot)
            result.addRepresentation(rep)
        }
        return result.representations.isEmpty ? icon : result
    }

    private func image(for row: Row) -> NSImage? {
        guard let text = row.thumb, let key = row.thumbKey else { return Self.appIcons[row.tool] ?? nil }
        if let cached = images[key] { return cached.image }
        guard let data = Data(base64Encoded: text), let image = NSImage(data: data) else { return nil }
        images[key] = (text.hashValue, image)
        return image
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("job")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? MonitorRowView) ?? MonitorRowView()
        view.identifier = id
        view.onMore = { [weak self, weak view] in
            guard let self = self, let view = view else { return }
            let index = self.table.row(for: view)
            guard index >= 0 else { return }
            self.buildMenu(forRow: index).popUp(
                positioning: nil, at: NSPoint(x: view.bounds.maxX - 6, y: view.bounds.midY), in: view)
        }
        view.onThumb = { [weak self, weak view] in
            guard let self = self, let view = view else { return }
            let index = self.table.row(for: view)
            if index >= 0, index < self.rows.count { self.openViewer(rows: index) }
        }
        view.update(rows[row], image: image(for: rows[row]), separator: rows[row].first && row > 0)
        return view
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in buildMenu(forRow: table.clickedRow).items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
    }

    private func buildMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()

        menu.autoenablesItems = false
        let job = NSMenuItem(title: MonitorText.cancelJob, action: #selector(cancelJob(_:)), keyEquivalent: "")
        job.target = self
        if row >= 0, row < rows.count {
            job.representedObject = rows[row].code
            job.isEnabled = rows[row].cancellable
        } else {
            job.isEnabled = false
        }
        let all = NSMenuItem(title: MonitorText.cancelAll, action: #selector(cancelAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = rows.contains { $0.cancellable }
        let save = NSMenuItem(title: MonitorText.saveAs, action: #selector(saveAs(_:)), keyEquivalent: "")
        save.target = self
        if row >= 0, row < rows.count, rows[row].saveable, rows[row].run != nil {
            save.representedObject = rows[row].code + "#" + String(rows[row].run!)
            save.isEnabled = true
        } else {
            save.isEnabled = false
        }
        let remove = NSMenuItem(title: MonitorText.remove, action: #selector(removeRow(_:)), keyEquivalent: "")
        remove.target = self
        if row >= 0, row < rows.count, rows[row].removable, let run = rows[row].run {
            remove.representedObject = rows[row].code + "#" + String(run)
            remove.isEnabled = true
        } else {
            remove.isEnabled = false
        }
        menu.addItem(job)
        menu.addItem(all)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(save)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(remove)
        return menu
    }

    private func row(code: String, run: Int) -> Row? {
        rows.first { $0.code == code && $0.run == run }
    }

    private func openViewer(rows index: Int) {
        MonitorTip.shared.hide()
        let row = rows[index]
        guard let run = row.run, row.thumb != nil else { return }
        viewing = (row.code, run, row.state, Date())
        viewerAsking = false
        askForPicture(code: row.code, run: run)
    }

    private func title(for row: Row) -> String {
        "\(row.project) \u{00B7} \(row.code) \u{00B7} Batch \(row.run ?? 0)"
    }

    private func askForPicture(code: String, run: Int) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DrawThingsQueueMonitor")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        viewerAsking = true
        send([
            "cmd": "preview", "code": code, "run": run,
            "out": directory.appendingPathComponent(UUID().uuidString + ".png").path,
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.viewerAsking = false }
    }

    private func showBigPicture(_ message: [String: Any]) {
        viewerAsking = false
        guard let current = viewing, message["code"] as? String == current.code,
            message["run"] as? Int == current.run
        else {
            if let path = message["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
            return
        }
        var image: NSImage?
        if message["ok"] as? Bool == true, let path = message["path"] as? String {
            image = NSImage(contentsOfFile: path)
            try? FileManager.default.removeItem(atPath: path)
        }
        guard let row = row(code: current.code, run: current.run) else { return }

        showImage(image ?? self.image(for: row), title: title(for: row), fresh: viewer?.isVisible != true)
    }

    private func showImage(_ image: NSImage?, title: String, fresh: Bool) {
        guard let image = image else { return }
        if viewer == nil {
            let window = ViewerWindow(
                contentRect: NSRect(x: 0, y: 0, width: 512, height: 512),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)

            window.isOpaque = MonitorColors.groundAlpha >= 1
            window.backgroundColor = MonitorColors.windowGround
            window.setFrameAutosaveName("QueueMonitorViewer")
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.delegate = self
            viewerImage = view
            viewer = window
        }
        viewerImage?.image = image
        viewer?.title = title
        guard fresh, let window = viewer else { return }

        let area = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let size = image.size
        let scale = min(area.width * 0.8 / max(size.width, 1), (area.height * 0.8 - 28) / max(size.height, 1), 1)
        let fitted = NSSize(width: max(size.width * scale, 256), height: max(size.height * scale, 256))
        window.setContentSize(fitted)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshViewer() {
        guard let current = viewing, viewer?.isVisible == true, !viewerAsking,
            let row = row(code: current.code, run: current.run), row.thumb != nil
        else { return }
        let changed = row.state != current.state
        if changed || (row.state == "running" && Date().timeIntervalSince(current.asked) >= 1) {
            viewing = (current.code, current.run, row.state, Date())
            askForPicture(code: current.code, run: current.run)
        }
    }

    @objc private func saveAs(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let parts = key.components(separatedBy: "#")
        guard parts.count == 2, let run = Int(parts[1]), let row = row(code: parts[0], run: run) else { return }
        let panel = NSSavePanel()

        panel.allowedContentTypes = row.video ? [.quickTimeMovie, .mpeg4Movie] : [.png]
        panel.nameFieldStringValue = "\(row.filename ?? "image-\(row.code)\(run)").\(row.video ? "mov" : "png")"
        panel.canCreateDirectories = true
        panel.title = MonitorText.saveAs
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DrawThingsQueueMonitor-" + UUID().uuidString)
            self.saves[key] = (url, directory)
            self.send(["cmd": "save", "code": row.code, "run": run, "dir": directory.path, "name": url.lastPathComponent])
        }
    }

    private func finishSave(_ message: [String: Any]) {
        guard let code = message["code"] as? String, let run = message["run"] as? Int,
            let pending = saves.removeValue(forKey: code + "#" + String(run))
        else { return }
        defer { try? FileManager.default.removeItem(at: pending.directory) }
        guard message["ok"] as? Bool == true, let files = message["files"] as? [String] else {
            alert(MonitorText.fileNotMade, message["message"] as? String ?? "")
            return
        }
        do {
            for file in files {
                let source = URL(fileURLWithPath: file)
                let destination =
                    files.count == 1
                    ? pending.destination
                    : pending.destination.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        } catch {
            alert(MonitorText.fileNotSaved, error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func cancelJob(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        send(["cmd": "cancel", "code": code])
    }

    @objc private func cancelAll() {
        send(["cmd": "cancelAll"])
    }

    @objc private func removeRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let parts = key.components(separatedBy: "#")
        guard parts.count == 2, let run = Int(parts[1]) else { return }
        send(["cmd": "remove", "code": parts[0], "run": run])
    }

}

final class MonitorRowView: NSTableCellView {
    private let thumb = ThumbView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")
    private let more = NSButton()
    private let rule = NSView()

    private let plate = PlateView()
    private static let plateInset: CGFloat = 6
    var onMore: (() -> Void)?

    var onThumb: (() -> Void)? {
        get { thumb.onClick }
        set { thumb.onClick = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = MonitorColors.background.cgColor
        projectLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        projectLabel.textColor = MonitorColors.muted
        line1.font = NSFont.systemFont(ofSize: 13)
        line2.font = NSFont.systemFont(ofSize: 11)
        line2.textColor = MonitorColors.muted
        for label in [projectLabel, line1, line2] { label.lineBreakMode = .byTruncatingTail }
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Menu")
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.contentTintColor = MonitorColors.muted
        more.target = self
        more.action = #selector(moreClicked)
        rule.wantsLayer = true
        rule.layer?.backgroundColor = MonitorColors.head.cgColor
        plate.isHidden = true
        for view in [plate, thumb, projectLabel, line1, line2, more, rule] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func moreClicked() {
        MonitorTip.shared.hide()
        onMore?()
    }

    private var detailText = ""
    private var tipTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        tipTimer?.invalidate()
        guard !detailText.isEmpty else { return }
        tipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self, !self.detailText.isEmpty else { return }
            MonitorTip.shared.show(self.detailText, owner: self, at: NSEvent.mouseLocation)
        }
    }

    override func mouseExited(with event: NSEvent) {
        tipTimer?.invalidate()
        MonitorTip.shared.hide(owner: self)
    }

    override func mouseDown(with event: NSEvent) {
        tipTimer?.invalidate()
        MonitorTip.shared.hide()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tipTimer?.invalidate()
            MonitorTip.shared.hide(owner: self)
        }
    }

    func update(_ row: QueueMonitor.Row, image: NSImage?, separator: Bool) {
        thumb.image = image

        thumb.clickable = row.thumb != nil
        thumb.layer?.backgroundColor = row.thumb != nil ? MonitorColors.background.cgColor : NSColor.clear.cgColor
        thumb.window?.invalidateCursorRects(for: thumb)

        toolTip = nil
        detailText = row.detail
        MonitorTip.shared.refresh(detailText, owner: self)
        projectLabel.stringValue = row.project
        line1.stringValue = row.line1
        line2.stringValue = row.line2 ?? ""
        line2.isHidden = row.line2 == nil
        switch row.state {
        case "pending", "cancelled": line1.textColor = MonitorColors.muted
        case "failed": line1.textColor = MonitorColors.failure
        default: line1.textColor = MonitorColors.text
        }

        projectLabel.textColor = row.open || row.tool ? MonitorColors.text : MonitorColors.muted
        alphaValue = row.open || row.tool ? 1 : 0.6
        layer?.backgroundColor = NSColor.clear.cgColor
        plate.isHidden = !row.open

        rule.isHidden = !separator || row.open
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let size: CGFloat = 48
        let inset = Self.plateInset

        plate.frame = NSRect(x: inset, y: 2, width: max(bounds.width - 2 * inset, 0), height: max(height - 4, 0))
        thumb.frame = NSRect(x: inset + 6, y: (height - size) / 2, width: size, height: size)
        let textX: CGFloat = inset + 6 + size + 10
        rule.frame = NSRect(x: inset, y: height - 1, width: max(bounds.width - 2 * inset, 0), height: 1)
        more.frame = NSRect(x: bounds.width - inset - 34, y: (height - 24) / 2, width: 28, height: 24)
        let textWidth = max(bounds.width - textX - inset - 40, 10)

        let heights: [CGFloat] = line2.isHidden ? [14, 18] : [14, 18, 15]
        var y = (height + heights.reduce(0, +)) / 2
        y -= heights[0]
        projectLabel.frame = NSRect(x: textX, y: y, width: textWidth, height: heights[0])
        y -= heights[1]
        line1.frame = NSRect(x: textX, y: y, width: textWidth, height: heights[1])
        if !line2.isHidden {
            y -= heights[2]
            line2.frame = NSRect(x: textX, y: y, width: textWidth, height: heights[2])
        }
    }
}

final class ThumbView: NSImageView {
    var onClick: (() -> Void)?
    var clickable = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if image != nil, clickable { onClick?() }
    }

    override func resetCursorRects() {
        if image != nil, clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class PlateView: NSView {
    static let radius: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {

        MonitorColors.highlight.withAlphaComponent(MonitorColors.groundAlpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

final class MonitorTip {
    static let shared = MonitorTip()

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private weak var owner: NSView?
    private static let padding = NSSize(width: 10, height: 8)
    private static let maxTextWidth: CGFloat = 320

    private init() {
        let box = TipBackground()
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = MonitorColors.text
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        box.addSubview(label)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = box
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    var isShown: Bool { panel.isVisible }

    func show(_ text: String, owner: NSView, at point: NSPoint) {
        self.owner = owner
        layout(text)

        var origin = NSPoint(x: point.x + 14, y: point.y - 18 - panel.frame.height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            origin.x = min(max(origin.x, area.minX + 4), area.maxX - panel.frame.width - 4)
            if origin.y < area.minY + 4 { origin.y = point.y + 18 }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func refresh(_ text: String, owner: NSView) {
        guard panel.isVisible, self.owner === owner else { return }
        let top = panel.frame.maxY
        layout(text)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    func hide(owner: NSView? = nil) {
        if let owner = owner, self.owner !== owner { return }
        panel.orderOut(nil)
        self.owner = nil
    }

    private func layout(_ text: String) {
        label.stringValue = text
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        let size = label.sizeThatFits(NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        let width = ceil(min(size.width, Self.maxTextWidth)) + 2 * Self.padding.width
        let height = ceil(size.height) + 2 * Self.padding.height
        label.frame = NSRect(
            x: Self.padding.width, y: Self.padding.height, width: width - 2 * Self.padding.width,
            height: height - 2 * Self.padding.height)
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView?.needsDisplay = true
    }
}

final class TipBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: PlateView.radius, yRadius: PlateView.radius)
        MonitorColors.highlight.setFill()
        shape.fill()
        MonitorColors.head.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}
