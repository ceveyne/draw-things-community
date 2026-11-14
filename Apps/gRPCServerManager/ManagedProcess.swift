import Cocoa
import Darwin

final class LogChannel {
    let title: String
    private let queue: DispatchQueue
    private var pending = ""
    private var text = ""
    private var timer: DispatchSourceTimer?
    private var window: NSWindow?
    private var textView: NSTextView?

    private let offset: CGFloat

    init(title: String, offset: CGFloat = 0) {
        self.title = title
        self.offset = offset
        queue = DispatchQueue(label: "com.satin-island.grpc-server-manager.log.\(title)")
    }

    func append(_ chunk: String) {
        queue.async {
            self.pending += chunk
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let chunk = self.pending
            self.pending = ""
            self.timer = nil
            if chunk.isEmpty { return }
            DispatchQueue.main.async { self.display(chunk) }
        }
        timer = t
        t.resume()
    }

    private func display(_ chunk: String) {
        text += chunk
        if text.count > 200_000 { text = String(text.suffix(150_000)) }
        if let tv = textView {
            tv.string = text
            let len = (tv.string as NSString).length
            tv.scrollRangeToVisible(NSRange(location: max(len - 1, 0), length: 1))
        }
    }

    func show() {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = title
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = NSColor.labelColor
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.insertionPointColor = NSColor.labelColor
        tv.drawsBackground = true
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(
                width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            tc.lineFragmentPadding = 4
        }
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        w.contentView?.addSubview(scroll)
        w.center()
        w.setFrameOrigin(NSPoint(x: w.frame.origin.x + offset, y: w.frame.origin.y - offset))
        window = w
        textView = tv
        tv.string = text
    }
}

final class ManagedProcess {
    let name: String
    let log: LogChannel

    var onChange: (() -> Void)?

    var onOutput: ((String) -> Void)?

    var onLaunched: (() -> Void)?

    var onEnded: ((_ requested: Bool) -> Void)?

    static let portWait: TimeInterval = 20
    static let earlyExit: TimeInterval = 10
    static let maxAttempts = 3
    static let retryDelay: TimeInterval = 2

    var restartsAfterCrash = false
    static let maxCrashRestarts = 5
    static let crashWindow: TimeInterval = 600
    private var crashTimes = [Date]()

    private(set) var process: Process?
    private var pipe: Pipe?

    private var stoppedProcess: Process?
    private(set) var starting = false
    private var token = 0

    init(name: String, log: LogChannel) {
        self.name = name
        self.log = log
    }

    var isRunning: Bool { process?.isRunning == true }

    var isBusy: Bool { process != nil || starting }

    private func note(_ message: String) {
        log.append("[\(name)] \(message)\n")
    }

    func start(
        executable: String, arguments: [String], ports: [Int],
        portsStayBusy: @escaping (Int) -> Void, failed: @escaping (Error) -> Void
    ) {
        guard !starting, process == nil || process === stoppedProcess else { return }
        starting = true
        token += 1
        onChange?()
        attempt(
            number: 1, token: token, since: Date(), executable: executable, arguments: arguments,
            ports: ports, portsStayBusy: portsStayBusy, failed: failed, notes: 0)
    }

    private func attempt(
        number: Int, token: Int, since: Date, executable: String, arguments: [String], ports: [Int],
        portsStayBusy: @escaping (Int) -> Void, failed: @escaping (Error) -> Void, notes: Int
    ) {
        guard token == self.token else { return }
        let leftover = process != nil
        let busyPort = ports.first { !Self.isPortAvailable($0) }
        if leftover || busyPort != nil {
            if Date().timeIntervalSince(since) > Self.portWait {
                starting = false
                onChange?()
                if let port = busyPort { portsStayBusy(port) }
                return
            }

            if notes % 4 == 0 {
                note(
                    leftover
                        ? "Waiting for the previous process to exit…"
                        : "Waiting for port \(busyPort!) to become free…")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attempt(
                    number: number, token: token, since: since, executable: executable,
                    arguments: arguments, ports: ports, portsStayBusy: portsStayBusy,
                    failed: failed, notes: notes + 1)
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        self.pipe = pipe
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty else {
                return
            }
            self?.log.append(s)
            DispatchQueue.main.async { self?.onOutput?(s) }
        }
        let launchedAt = Date()
        proc.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                self?.didTerminate(
                    ended, number: number, token: token, launchedAt: launchedAt,
                    executable: executable, arguments: arguments, ports: ports,
                    portsStayBusy: portsStayBusy, failed: failed)
            }
        }
        do {
            try proc.run()
            process = proc
            starting = false
            if number > 1 { note("Started (attempt \(number))") }
            onLaunched?()
            onChange?()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.pipe = nil
            starting = false
            onChange?()
            failed(error)
        }
    }

    private func didTerminate(
        _ ended: Process, number: Int, token: Int, launchedAt: Date, executable: String,
        arguments: [String], ports: [Int], portsStayBusy: @escaping (Int) -> Void,
        failed: @escaping (Error) -> Void
    ) {
        guard process === ended else { return }
        process = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        let lived = Date().timeIntervalSince(launchedAt)
        let requested = ended === stoppedProcess
        if requested { stoppedProcess = nil }
        if !requested, lived < Self.earlyExit, number < Self.maxAttempts, token == self.token {
            note(
                "Exited after \(String(format: "%.1f", lived)) s (status \(ended.terminationStatus)), starting again (\(number + 1)/\(Self.maxAttempts))…"
            )
            starting = true
            onChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.attempt(
                    number: number + 1, token: token, since: Date(), executable: executable,
                    arguments: arguments, ports: ports, portsStayBusy: portsStayBusy,
                    failed: failed, notes: 0)
            }
            return
        }
        if !requested {
            note("Exited unexpectedly after \(String(format: "%.1f", lived)) s (status \(ended.terminationStatus))")
        }
        if !requested, restartsAfterCrash, token == self.token {
            let now = Date()
            crashTimes = crashTimes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
            if crashTimes.count <= Self.maxCrashRestarts {
                note(
                    "Crashed (status \(ended.terminationStatus)); starting again (\(crashTimes.count)/\(Self.maxCrashRestarts) within \(Int(Self.crashWindow / 60)) min)…"
                )
                starting = true
                onChange?()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                    self?.attempt(
                        number: 1, token: token, since: Date(), executable: executable,
                        arguments: arguments, ports: ports, portsStayBusy: portsStayBusy,
                        failed: failed, notes: 0)
                }
                return
            }
            note("Crashed \(crashTimes.count) times within \(Int(Self.crashWindow / 60)) min; not started again.")
        }
        onChange?()
        onEnded?(requested)
    }

    func stop() {
        token += 1
        let wasStarting = starting
        starting = false
        guard let proc = process else {
            if wasStarting { onChange?() }
            return
        }
        stoppedProcess = proc
        proc.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            if let still = self?.process, still === proc, still.isRunning { still.interrupt() }
        }
        onChange?()
    }

    func terminateNow() {
        token += 1
        starting = false
        stoppedProcess = process
        process?.terminate()
        pipe?.fileHandleForReading.readabilityHandler = nil
    }

    static func isPortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return true }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))
        return withUnsafePointer(to: &addr) { ptr -> Bool in
            let res = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            if res == 0 { return true }
            return errno != EADDRINUSE
        }
    }
}
