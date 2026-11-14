import Cocoa
import Darwin
import ServiceManagement

private enum L10n {
    static var isGerman: Bool {
        Locale.preferredLanguages.first?.hasPrefix("de") == true
    }

    static var startServer: String { isGerman ? "Server starten" : "Start Server" }
    static var stopServer: String { isGerman ? "Server stoppen" : "Stop Server" }
    static var modelBrowserActive: String {
        isGerman ? "Model Browser aktiv" : "Model Browser Active"
    }
    static var tlsActive: String { isGerman ? "TLS aktiv" : "TLS Active" }
    static var setPort: String { isGerman ? "Port setzen…" : "Set Port…" }
    static var setSharedSecret: String { isGerman ? "Shared Secret setzen…" : "Set Shared Secret…" }
    static var chooseModelsPath: String {
        isGerman ? "Modelle-Pfad wählen…" : "Choose Models Path…"
    }
    static var chooseBinaryPath: String { isGerman ? "Binary-Pfad wählen…" : "Choose Binary Path…" }
    static var launchAtLogin: String { isGerman ? "Bei Anmeldung starten" : "Launch at Login" }
    static var showLogs: String { isGerman ? "Logs anzeigen" : "Show Logs" }
    static var useProxy: String { isGerman ? "Proxy verwenden" : "Use Proxy" }
    static var setProxyPort: String { isGerman ? "Proxy-Port setzen…" : "Set Proxy Port…" }
    static var fixHistory: String {
        isGerman ? "Verlauf anpassen" : "Sync History"
    }
    static var fixHistoryTitle: String {
        isGerman ? "Versionsverlauf anpassen?" : "Sync Version History?"
    }
    static var fixHistoryInfo: String {
        isGerman
            ? "Experimentelle Funktion, bitte mit Vorsicht benutzen. Sie schreibt in die Historie des Projekts in Draw Things, damit den Bildern aus der Queue die richtigen Generierungsdaten zugeordnet werden. Sichere wichtige Projekte vorher. Gilt ab dem nächsten Start des Proxys."
            : "Experimental feature, use with care. It writes into the history of the project in Draw Things, so that the images from the queue get the right generation data. Back up important projects first. Applies from the next start of the proxy."
    }
    static var fixHistoryConfirm: String { isGerman ? "Verlauf anpassen" : "Sync History" }
    static var issueReceipt: String { isGerman ? "Receipt ausstellen" : "Issue Receipt" }
    static var queueMonitor: String { "Queue Monitor" }
    static var emptyQueue: String { isGerman ? "Queue leeren…" : "Empty Queue…" }
    static var emptyQueueTitle: String { isGerman ? "Queue leeren?" : "Empty the queue?" }
    static var emptyQueueInfo: String {
        isGerman
            ? "Alle Jobs werden abgebrochen und alle Bilder gelöscht (auch die im Queue Monitor gezeigten und die noch nicht ausgelieferten), ebenso alles andere, was der Proxy aufbewahrt (Statusbilder, Historien-Journal). Das lässt sich nicht rückgängig machen."
            : "All jobs are cancelled and all images are deleted (those shown in the queue monitor and those not delivered yet), as is everything else the proxy keeps (status images, history journal). This cannot be undone."
    }
    static var emptyQueueConfirm: String { isGerman ? "Queue leeren" : "Empty Queue" }
    static var quit: String { isGerman ? "Beenden" : "Quit" }

    static var serverStopped: String { isGerman ? "Server gestoppt" : "Server Stopped" }
    static var serverStarting: String { isGerman ? "Server startet…" : "Server Starting…" }
    static func proxyRunning(port: Int) -> String {
        isGerman ? "Proxy läuft auf Port \(port)" : "Proxy running on port \(port)"
    }
    static func serverRunning(tls: Bool, port: Int) -> String {
        isGerman
            ? "Server läuft (TLS: \(tls ? "an" : "aus"), Port: \(port))"
            : "Server Running (TLS: \(tls ? "on" : "off"), Port: \(port))"
    }

    static var serverNotStarted: String {
        isGerman ? "Server nicht gestartet" : "Server Not Started"
    }
    static func portInUse(_ port: Int) -> String {
        isGerman
            ? "Port \(port) wird bereits genutzt. Beende den anderen Server oder wähle einen anderen Port."
            : "Port \(port) is already in use. Stop the other server or choose a different port."
    }
    static var setProxyPortTitle: String { isGerman ? "Proxy-Port setzen" : "Set Proxy Port" }
    static var setProxyPortInfo: String {
        isGerman
            ? "Auf diesem Port erreicht die App den Proxy (z. B. 7861). Er muss sich vom Server-Port unterscheiden."
            : "The app connects to the proxy on this port (e.g. 7861). It must differ from the server port."
    }
    static var proxyNotStarted: String { isGerman ? "Proxy nicht gestartet" : "Proxy Not Started" }
    static var projectsAccessTitle: String {
        isGerman ? "Lesezugriff auf Draw-Things-Projekte erteilen" : "Grant read access to Draw Things Projects"
    }
    static var projectsAccessInfo: String {
        isGerman
            ? "Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner > gRPC Server Manager: \"Draw Things\" aktivieren."
            : "System Settings > Privacy & Security > Files & Folders > gRPC Server Manager: switch on \"Draw Things\"."
    }
    static var openSettings: String { isGerman ? "Einstellungen öffnen" : "Open Settings" }
    static var later: String { isGerman ? "Später" : "Later" }
    static var proxyPortEqualsServerPort: String {
        isGerman
            ? "Der Proxy-Port muss sich vom Server-Port unterscheiden."
            : "The proxy port must differ from the server port."
    }
    static var setPortTitle: String { isGerman ? "Port setzen" : "Set Port" }
    static var setPortInfo: String {
        isGerman ? "Gib den TCP-Port an (z. B. 7859)." : "Enter the TCP port (e.g. 7859)."
    }
    static var setSecretTitle: String { isGerman ? "Shared Secret setzen" : "Set Shared Secret" }
    static var setSecretInfo: String {
        isGerman ? "Leerlassen zum Entfernen." : "Leave empty to remove."
    }
    static var ok: String { "OK" }
    static var cancel: String { isGerman ? "Abbrechen" : "Cancel" }

    static var weightsCacheSize: String { isGerman ? "Weights-Cache-Größe" : "Weights Cache Size" }
    static var disabled: String { isGerman ? "Deaktiviert" : "Disabled" }

    static var debugLogging: String { isGerman ? "Debug-Logging" : "Debug Logging" }

    static var logWindowTitle: String { "gRPC Server Logs" }
    static var proxyLogWindowTitle: String { "gRPC Proxy Logs" }

    static func gcDeleted(_ file: String) -> String {
        "[GC] \(isGerman ? "Gelöscht" : "Deleted"): \(file)\n"
    }
    static func gcDeleteError(_ file: String, _ error: String) -> String {
        "[GC] \(isGerman ? "Fehler beim Löschen von" : "Error deleting") \(file): \(error)\n"
    }
    static func gcSummary(_ count: Int) -> String {
        "[GC] \(count) .bin-\(isGerman ? "Datei(en) gelöscht" : "file(s) deleted")\n"
    }
    static var gcNoFiles: String {
        "[GC] \(isGerman ? "Keine veralteten .bin-Dateien gefunden" : "No outdated .bin files found")\n"
    }
    static func gcScanError(_ dir: String, _ error: String) -> String {
        "[GC] \(isGerman ? "Fehler beim Scannen von" : "Error scanning") \(dir): \(error)\n"
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let serverLog = LogChannel(title: L10n.logWindowTitle)
    private let proxyLog = LogChannel(title: L10n.proxyLogWindowTitle, offset: 40)
    private lazy var server = ManagedProcess(name: "Server", log: serverLog)
    private lazy var proxy = ManagedProcess(name: "Proxy", log: proxyLog)

    private let logQueue = DispatchQueue(label: "com.satin-island.grpc-server-manager.logqueue")
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var proxyItem: NSMenuItem?
    private var monitorItem: NSMenuItem?
    private var proxyPortItem: NSMenuItem?
    private var fixHistoryItem: NSMenuItem?
    private var issueReceiptItem: NSMenuItem?
    private var emptyQueueItem: NSMenuItem?
    private let monitorSocketPath =
        NSHomeDirectory() + "/Library/Application Support/gRPC Server Manager/proxy/monitor.sock"
    private lazy var queueMonitor = QueueMonitor(socketPath: monitorSocketPath)
    private var gcTimer: DispatchSourceTimer?
    private var debugLogHandle: FileHandle?
    private var autoRestartAttempts = 0
    private let autoRestartMaxAttempts = 150
    private let autoRestartInterval: TimeInterval = 2.0

    private let defaultModelsPath =
        ("~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models" as NSString)
        .expandingTildeInPath
    private let binPathDefault = "/usr/local/bin/gRPCServerCLI-macOS"
    private let kModelsPath = "modelsPath"
    private let kModelBrowser = "modelBrowser"
    private let kBinPath = "binPath"
    private let kTLS = "tlsEnabled"
    private let kPort = "port"
    private let kSharedSecret = "sharedSecret"
    private let kDebug = "debugEnabled"
    private let kWeightsCache = "weightsCacheGiB"
    private let kAutoRestart = "serverAutoRestart"
    private let kUseProxy = "proxyEnabled"
    private let kProxyPort = "proxyPort"
    private let kFixHistory = "proxyFixHistory"
    private let kIssueReceipt = "proxyIssueReceipt"
    private let proxyPortDefault = 7861

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: [kModelBrowser: true])
        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()

        if var appIcon = NSImage(
            systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        {
            if #available(macOS 11.0, *) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 256, weight: .regular)
                if let configured = appIcon.withSymbolConfiguration(cfg) { appIcon = configured }
            }
            appIcon.isTemplate = false
            appIcon.size = NSSize(width: 512, height: 512)
            NSApp.applicationIconImage = appIcon
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {

            if let img = NSImage(
                systemSymbolName: "photo", accessibilityDescription: "gRPC Server")
            {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "gRPC"
            }
            button.toolTip = L10n.serverStopped
        }

        let menu = NSMenu()

        menu.autoenablesItems = false
        let sItem = NSMenuItem(
            title: L10n.startServer, action: #selector(startServer), keyEquivalent: "")
        let xItem = NSMenuItem(
            title: L10n.stopServer, action: #selector(stopServer), keyEquivalent: "")
        menu.addItem(sItem)
        menu.addItem(xItem)
        startItem = sItem
        stopItem = xItem
        menu.addItem(NSMenuItem.separator())
        let modelBrowserItem = NSMenuItem(
            title: L10n.modelBrowserActive, action: #selector(toggleModelBrowser), keyEquivalent: ""
        )
        modelBrowserItem.state = UserDefaults.standard.bool(forKey: kModelBrowser) ? .on : .off
        menu.addItem(modelBrowserItem)

        let tlsItem = NSMenuItem(
            title: L10n.tlsActive, action: #selector(toggleTLS), keyEquivalent: "")
        if UserDefaults.standard.object(forKey: kTLS) == nil {
            UserDefaults.standard.set(true, forKey: kTLS)
        }
        tlsItem.state = UserDefaults.standard.bool(forKey: kTLS) ? .on : .off
        menu.addItem(tlsItem)

        menu.addItem(withTitle: L10n.setPort, action: #selector(setPort), keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.setSharedSecret, action: #selector(setSharedSecret),
            keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.chooseModelsPath, action: #selector(chooseModelsPath),
            keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.chooseBinaryPath, action: #selector(chooseBinPath), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let proxyItem = NSMenuItem(
            title: L10n.useProxy, action: #selector(toggleProxy), keyEquivalent: "")
        self.proxyItem = proxyItem
        menu.addItem(proxyItem)
        proxyPortItem = menu.addItem(
            withTitle: L10n.setProxyPort, action: #selector(setProxyPort), keyEquivalent: "")
        let fixHistoryItem = NSMenuItem(
            title: L10n.fixHistory, action: #selector(toggleFixHistory), keyEquivalent: "")
        fixHistoryItem.state = UserDefaults.standard.bool(forKey: kFixHistory) ? .on : .off
        self.fixHistoryItem = fixHistoryItem
        menu.addItem(fixHistoryItem)
        let issueReceiptItem = NSMenuItem(
            title: L10n.issueReceipt, action: #selector(toggleIssueReceipt), keyEquivalent: "")
        issueReceiptItem.state = UserDefaults.standard.bool(forKey: kIssueReceipt) ? .on : .off
        self.issueReceiptItem = issueReceiptItem
        menu.addItem(issueReceiptItem)
        let monitorMenuItem = NSMenuItem(
            title: L10n.queueMonitor, action: #selector(toggleQueueMonitor), keyEquivalent: "")
        monitorItem = monitorMenuItem
        menu.addItem(monitorMenuItem)
        queueMonitor.onChange = { [weak self] in self?.updateStatusUI() }
        emptyQueueItem = menu.addItem(
            withTitle: L10n.emptyQueue, action: #selector(emptyQueue), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let weightsCacheItem = NSMenuItem(
            title: L10n.weightsCacheSize, action: nil, keyEquivalent: "")
        let weightsCacheMenu = NSMenu()
        let currentCache = UserDefaults.standard.integer(forKey: kWeightsCache)
        for gib in [0, 8, 16, 24, 32] {
            let label = gib == 0 ? L10n.disabled : "\(gib) GiB"
            let item = NSMenuItem(
                title: label, action: #selector(setWeightsCache(_:)), keyEquivalent: "")
            item.tag = gib
            item.state = currentCache == gib ? .on : .off
            weightsCacheMenu.addItem(item)
        }
        weightsCacheItem.submenu = weightsCacheMenu
        menu.addItem(weightsCacheItem)
        menu.addItem(NSMenuItem.separator())
        let launchItem = NSMenuItem(
            title: L10n.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.showLogs, action: #selector(showLogs), keyEquivalent: "l")

        let debugItem = NSMenuItem(
            title: L10n.debugLogging, action: #selector(toggleDebug), keyEquivalent: "")
        debugItem.state = UserDefaults.standard.bool(forKey: kDebug) ? .on : .off
        menu.addItem(debugItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        server.onChange = { [weak self] in self?.updateStatusUI() }
        proxy.restartsAfterCrash = true
        proxy.onChange = { [weak self] in self?.updateStatusUI() }
        proxy.onLaunched = { [weak self] in self?.projectsAlertShown = false }
        proxy.onOutput = { [weak self] chunk in self?.watchProxyOutput(chunk) }
        server.onOutput = { [weak self] chunk in self?.teeToDebugLog(chunk) }
        server.onLaunched = { [weak self] in self?.serverLaunched() }
        server.onEnded = { [weak self] requested in self?.serverEnded(requested: requested) }
        updateStatusUI()
        if QueueMonitor.wasOpen { queueMonitor.show(activate: false) }

        if UserDefaults.standard.bool(forKey: kAutoRestart) {
            scheduleAutoRestart()
        }

        if useProxy { checkProjectsAccess {} }
    }

    private func setupEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")

        func add(
            _ title: String, _ action: Selector, _ key: String,
            _ mods: NSEvent.ModifierFlags = .command
        ) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            edit.addItem(it)
        }
        add("Undo", #selector(UndoManager.undo), "z")
        add("Redo", #selector(UndoManager.redo), "Z")
        edit.addItem(NSMenuItem.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Select All", #selector(NSText.selectAll(_:)), "a")

        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func scheduleAutoRestart() {

        guard !server.isBusy, UserDefaults.standard.bool(forKey: kAutoRestart) else { return }
        let models = UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: models, isDirectory: &isDir), isDir.boolValue {
            startServer()
            return
        }
        autoRestartAttempts += 1
        if autoRestartAttempts > autoRestartMaxAttempts {
            serverLog.append("[AutoRestart] Gave up waiting for models path: \(models)\n")
            return
        }
        serverLog.append(
            "[AutoRestart] Waiting for models path to become available (\(autoRestartAttempts)/\(autoRestartMaxAttempts)): \(models)\n"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + autoRestartInterval) { [weak self] in
            self?.scheduleAutoRestart()
        }
    }

    private var serverPort: Int {
        (UserDefaults.standard.object(forKey: kPort) as? Int) ?? 7859
    }

    private var proxyPort: Int {
        (UserDefaults.standard.object(forKey: kProxyPort) as? Int) ?? proxyPortDefault
    }

    private var useProxy: Bool { UserDefaults.standard.bool(forKey: kUseProxy) }

    @objc private func startServer() {
        guard !server.isBusy else { return }

        let bin = UserDefaults.standard.string(forKey: kBinPath) ?? binPathDefault
        let models = UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath
        let modelBrowser = UserDefaults.standard.bool(forKey: kModelBrowser)
        let tlsEnabled = UserDefaults.standard.bool(forKey: kTLS)
        let sharedSecret = UserDefaults.standard.string(forKey: kSharedSecret) ?? ""
        let port = serverPort

        serverLog.append("[Config] Binary: \(bin)\n")
        serverLog.append("[Config] Models: \(models)\n")
        serverLog.append("[Config] Port: \(port), TLS: \(tlsEnabled), ModelBrowser: \(modelBrowser)\n")
        let cacheLog = UserDefaults.standard.integer(forKey: kWeightsCache)
        serverLog.append("[Config] WeightsCache: \(cacheLog == 0 ? "disabled" : "\(cacheLog) GiB")\n")

        cleanupBinFiles(modelsDir: models)

        var args: [String] = []
        args.append(models)
        if modelBrowser { args += ["--model-browser"] }
        if !tlsEnabled { args += ["--no-tls"] }
        if port > 0 { args += ["--port", String(port)] }
        if !sharedSecret.isEmpty { args += ["--shared-secret", sharedSecret] }
        if UserDefaults.standard.bool(forKey: kDebug) { args += ["--debug"] }
        let cacheGiB = UserDefaults.standard.integer(forKey: kWeightsCache)
        if cacheGiB > 0 { args += ["-w", String(cacheGiB)] }

        server.start(
            executable: bin, arguments: args, ports: port > 0 ? [port] : [],
            portsStayBusy: { [weak self] busy in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.serverNotStarted
                alert.informativeText = L10n.portInUse(busy)
                alert.runModal()
                self?.updateStatusUI()
            },
            failed: { error in NSAlert(error: error).runModal() })
        if useProxy { startProxy() }
    }

    private func serverLaunched() {
        UserDefaults.standard.set(true, forKey: kAutoRestart)
        let models = UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath
        if UserDefaults.standard.bool(forKey: kDebug) { openDebugLog(models: models) }
        startGCTimer(modelsDir: models)
    }

    private func serverEnded(requested: Bool) {
        stopGCTimer()
        if !server.isBusy { closeDebugLog() }

        if !requested { stopProxy() }
    }

    private var checkingProjectsAccess = false
    private var projectsAlertShown = false
    private var proxyOutputTail = ""

    private func watchProxyOutput(_ chunk: String) {
        proxyOutputTail = String((proxyOutputTail + chunk).suffix(600))
        guard !projectsAlertShown, proxyOutputTail.contains("projects directory"),
            proxyOutputTail.contains("cannot be read")
        else { return }
        projectsAlertShown = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.projectsAccessTitle
        alert.informativeText = L10n.projectsAccessInfo
        alert.addButton(withTitle: L10n.openSettings)
        alert.addButton(withTitle: L10n.later)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        {
            NSWorkspace.shared.open(url)
        }
    }

    private var accessResetTried = false

    private func checkProjectsAccess(completion: @escaping () -> Void) {
        guard !checkingProjectsAccess else { return }
        checkingProjectsAccess = true
        let data = ("~/Library/Containers/com.liuliu.draw-things/Data/Documents" as NSString)
            .expandingTildeInPath
        proxyLog.append("[Access] Checking access to the Draw Things projects (macOS may ask now)…\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func probe() -> (allowed: Bool, text: String) {
                var detail = ""
                var allowed = false
                do {
                    let names = try FileManager.default.contentsOfDirectory(atPath: data)
                    allowed = true
                    detail = "\(names.filter { $0.hasSuffix(".sqlite3") }.count) projects found"
                } catch {
                    detail = "folder: \(error.localizedDescription)"
                }

                if let handle = FileHandle(forReadingAtPath: data + "/Models/custom_configs.json") {
                    _ = try? handle.read(upToCount: 1)
                    try? handle.close()
                    allowed = true
                    detail += detail.isEmpty ? "models file readable" : "; models file readable"
                }
                return (allowed, detail)
            }
            var result = probe()
            var note = ""
            if !result.allowed, let self = self, !self.accessResetTried,
                let bundle = Bundle.main.bundleIdentifier
            {

                self.accessResetTried = true
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "SystemPolicyAppData", bundle]
                let pipe = Pipe()
                reset.standardOutput = pipe
                reset.standardError = pipe
                try? reset.run()
                reset.waitUntilExit()
                note = "[Access] Denied (\(result.text)); the entry of the manager was reset (tccutil exit \(reset.terminationStatus)) and macOS is asked again…\n"
                result = probe()
            }
            let text =
                result.allowed
                ? "[Access] Allowed: \(result.text).\n"
                : "[Access] Denied (\(result.text)). macOS did not ask or the answer was no. The proxy will report whether it can read the projects itself.\n"
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingProjectsAccess = false
                if !note.isEmpty { self.proxyLog.append(note) }
                self.proxyLog.append(text)
                completion()
            }
        }
    }

    private func startProxy() {
        guard !proxy.isBusy, !checkingProjectsAccess else { return }
        checkProjectsAccess { [weak self] in

            if self?.server.isBusy == true { self?.launchProxy() }
        }
    }

    private func launchProxy() {
        guard !proxy.isBusy else { return }

        let serverBin = UserDefaults.standard.string(forKey: kBinPath) ?? binPathDefault
        let bin =
            Bundle.main.url(forAuxiliaryExecutable: "gRPCServerProxy")?.path
            ?? (serverBin as NSString).deletingLastPathComponent + "/gRPCServerProxy"
        let models = UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath
        let port = proxyPort
        if port == serverPort {
            proxyLog.append("[Proxy] Not started: the proxy port \(port) equals the server port.\n")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.proxyNotStarted
            alert.informativeText = L10n.proxyPortEqualsServerPort
            alert.runModal()
            return
        }
        var args = [models, "--port", String(port), "--upstream-port", String(serverPort)]
        if !UserDefaults.standard.bool(forKey: kTLS) { args += ["--no-tls"] }
        let secret = UserDefaults.standard.string(forKey: kSharedSecret) ?? ""
        if !secret.isEmpty { args += ["--shared-secret", secret] }

        let fixHistory = UserDefaults.standard.bool(forKey: kFixHistory)
        args.append(fixHistory ? "--sync-history" : "--no-sync-history")
        let issueReceipt = UserDefaults.standard.bool(forKey: kIssueReceipt)
        args.append(issueReceipt ? "--issue-receipts" : "--no-issue-receipts")
        args += ["--monitor-socket", monitorSocketPath]
        args += ["--language", L10n.isGerman ? "de" : "en"]
        proxyLog.append("[Config] Binary: \(bin)\n")
        proxyLog.append(
            "[Config] Proxy port: \(port), upstream port: \(serverPort), sync history: \(fixHistory ? "on" : "off"), issue receipts: \(issueReceipt ? "on" : "off")\n")
        proxy.start(
            executable: bin, arguments: args, ports: [port],
            portsStayBusy: { [weak self] busy in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.proxyNotStarted
                alert.informativeText = L10n.portInUse(busy)
                alert.runModal()
                self?.updateStatusUI()
            },
            failed: { error in NSAlert(error: error).runModal() })
    }

    private func stopProxy() {
        proxy.stop()
    }

    @objc private func stopServer() {
        guard server.isBusy else { return }

        UserDefaults.standard.set(false, forKey: kAutoRestart)
        terminateServerProcess()
    }

    private func terminateServerProcess() {
        stopGCTimer()
        closeDebugLog()
        proxy.stop()
        server.stop()
    }

    private func openDebugLog(models: String) {
        let logPath = URL(fileURLWithPath: models).appendingPathComponent("grpc-server-debug.log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let fh = FileHandle(forWritingAtPath: logPath)
        fh?.seekToEndOfFile()
        logQueue.async {
            self.debugLogHandle?.closeFile()
            self.debugLogHandle = fh
        }
        serverLog.append("[Debug] Logging to: \(logPath)\n")
    }

    private func closeDebugLog() {

        logQueue.async {
            self.debugLogHandle?.closeFile()
            self.debugLogHandle = nil
        }
    }

    private func teeToDebugLog(_ chunk: String) {

        logQueue.async {
            self.debugLogHandle?.write(Data(chunk.utf8))
        }
    }

    @objc private func toggleModelBrowser(_ sender: NSMenuItem) {
        let newVal = !UserDefaults.standard.bool(forKey: kModelBrowser)
        UserDefaults.standard.set(newVal, forKey: kModelBrowser)
        sender.state = newVal ? .on : .off
    }

    @objc private func toggleTLS(_ sender: NSMenuItem) {
        let newVal = !UserDefaults.standard.bool(forKey: kTLS)
        UserDefaults.standard.set(newVal, forKey: kTLS)
        sender.state = newVal ? .on : .off
    }

    @objc private func toggleDebug(_ sender: NSMenuItem) {
        let newVal = !UserDefaults.standard.bool(forKey: kDebug)
        UserDefaults.standard.set(newVal, forKey: kDebug)
        sender.state = newVal ? .on : .off

        if server.isRunning {
            if newVal {
                openDebugLog(
                    models: UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath)
            } else {
                closeDebugLog()
            }
        }
    }

    @objc private func setWeightsCache(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kWeightsCache)
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    @objc private func setPort() {
        let current = (UserDefaults.standard.object(forKey: kPort) as? Int) ?? 7859
        let alert = NSAlert()
        alert.messageText = L10n.setPortTitle
        alert.informativeText = L10n.setPortInfo
        alert.addButton(withTitle: L10n.ok)
        alert.addButton(withTitle: L10n.cancel)
        let tf = NSTextField(string: String(current))
        tf.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            if let val = Int(tf.stringValue), val > 0 && val < 65536 {
                UserDefaults.standard.set(val, forKey: kPort)
            }
        }
    }

    @objc private func setSharedSecret() {
        let current = UserDefaults.standard.string(forKey: kSharedSecret) ?? ""
        let alert = NSAlert()
        alert.messageText = L10n.setSecretTitle
        alert.informativeText = L10n.setSecretInfo
        alert.addButton(withTitle: L10n.ok)
        alert.addButton(withTitle: L10n.cancel)
        let tf = NSSecureTextField(string: current)
        tf.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue
            if v.isEmpty {
                UserDefaults.standard.removeObject(forKey: kSharedSecret)
            } else {
                UserDefaults.standard.set(v, forKey: kSharedSecret)
            }
        }
    }

    @objc private func toggleProxy(_ sender: NSMenuItem) {
        let newVal = !useProxy

        let firstTime = UserDefaults.standard.object(forKey: kUseProxy) == nil
        UserDefaults.standard.set(newVal, forKey: kUseProxy)
        if newVal && firstTime {
            UserDefaults.standard.set(false, forKey: kFixHistory)
            UserDefaults.standard.set(true, forKey: kIssueReceipt)
            fixHistoryItem?.state = .off
            issueReceiptItem?.state = .on
            queueMonitor.show()
        }
        updateStatusUI()

        if server.isRunning {
            if newVal { startProxy() } else { stopProxy() }
        }
    }

    @objc private func toggleQueueMonitor() {
        queueMonitor.toggle()
    }

    private var proxyStateDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/gRPC Server Manager/proxy"
    }

    @objc private func emptyQueue() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.emptyQueueTitle
        alert.informativeText = L10n.emptyQueueInfo
        alert.addButton(withTitle: L10n.emptyQueueConfirm)
        alert.addButton(withTitle: L10n.cancel)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let restart = proxy.isBusy
        if proxy.isBusy { proxy.stop() }
        var waited = 0.0
        func erase() {
            let directory = proxyStateDirectory
            var failed = [String]()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                do {
                    try FileManager.default.removeItem(atPath: directory + "/" + name)
                } catch {
                    failed.append("\(name): \(error.localizedDescription)")
                }
            }
            proxyLog.append(
                failed.isEmpty
                    ? "[Queue] Emptied: everything in \(directory) is erased.\n"
                    : "[Queue] Emptied, but not erased: \(failed.joined(separator: "; "))\n")
            if restart && useProxy && server.isRunning { startProxy() }
        }
        func wait() {
            if proxy.isBusy && waited < 15 {
                waited += 0.2
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait() }
            } else {
                erase()
            }
        }
        wait()
    }

    @objc private func toggleFixHistory(_ sender: NSMenuItem) {
        let newVal = !UserDefaults.standard.bool(forKey: kFixHistory)
        if newVal {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.fixHistoryTitle
            alert.informativeText = L10n.fixHistoryInfo
            alert.addButton(withTitle: L10n.fixHistoryConfirm)
            alert.addButton(withTitle: L10n.cancel)

            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(newVal, forKey: kFixHistory)
        sender.state = newVal ? .on : .off
    }

    @objc private func toggleIssueReceipt(_ sender: NSMenuItem) {
        let newVal = !UserDefaults.standard.bool(forKey: kIssueReceipt)
        UserDefaults.standard.set(newVal, forKey: kIssueReceipt)
        sender.state = newVal ? .on : .off
    }

    @objc private func setProxyPort() {
        let alert = NSAlert()
        alert.messageText = L10n.setProxyPortTitle
        alert.informativeText = L10n.setProxyPortInfo
        alert.addButton(withTitle: L10n.ok)
        alert.addButton(withTitle: L10n.cancel)
        let tf = NSTextField(string: String(proxyPort))
        tf.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            if let val = Int(tf.stringValue), val > 0 && val < 65536 {
                UserDefaults.standard.set(val, forKey: kProxyPort)
            }
        }
    }

    @objc private func chooseModelsPath() {
        let currentPath = UserDefaults.standard.string(forKey: kModelsPath) ?? defaultModelsPath
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: currentPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: self.kModelsPath)
            UserDefaults.standard.synchronize()

            let saved = UserDefaults.standard.string(forKey: self.kModelsPath)
            self.serverLog.append("[Settings] Saved modelsPath: \(saved ?? "nil")\n")
        }
    }

    @objc private func chooseBinPath() {
        let currentPath = UserDefaults.standard.string(forKey: kBinPath) ?? binPathDefault
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: self.kBinPath)
            UserDefaults.standard.synchronize()
        }
    }

    @objc private func showLogs() {
        if useProxy { proxyLog.show() }
        serverLog.show()
    }

    @objc private func quit() {
        terminateServerProcess()
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let on = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(on)
        sender.state = on ? .on : .off
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return FileManager.default.fileExists(atPath: launchAgentPlistPath().path)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch { NSLog("LaunchAtLogin error: %@", error.localizedDescription) }
        } else {
            let plistURL = launchAgentPlistPath()
            if enable {
                let plist: [String: Any] = [
                    "Label": "com.satin-island.grpc-server-manager",
                    "RunAtLoad": true,
                    "KeepAlive": false,
                    "ProgramArguments": [
                        Bundle.main.bundlePath + "/Contents/MacOS/"
                            + (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
                                ?? "gRPCServerManager")
                    ],
                ]
                do {
                    let data = try PropertyListSerialization.data(
                        fromPropertyList: plist, format: .xml, options: 0)
                    try data.write(to: plistURL)
                } catch { NSLog("LaunchAgent write error: %@", error.localizedDescription) }
            } else {
                try? FileManager.default.removeItem(at: plistURL)
            }
        }
    }

    private func launchAgentPlistPath() -> URL {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        return URL(fileURLWithPath: dir).appendingPathComponent(
            "com.satin-island.grpc-server-manager.plist")
    }

    private func isRunning() -> Bool { server.isRunning }

    private func updateStatusUI() {
        let running = isRunning()
        let starting = server.starting

        let symbol = running ? "photo.on.rectangle" : "photo"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "gRPC Server") {
            img.isTemplate = true
            statusItem.button?.image = img
        }

        let tls = UserDefaults.standard.bool(forKey: kTLS)
        var tip =
            running
            ? L10n.serverRunning(tls: tls, port: serverPort)
            : (starting ? L10n.serverStarting : L10n.serverStopped)
        if running, proxy.isRunning { tip += "\n" + L10n.proxyRunning(port: proxyPort) }
        statusItem.button?.toolTip = tip

        let startsWithManager = server.isBusy || UserDefaults.standard.bool(forKey: kAutoRestart)
        startItem?.state = startsWithManager ? .on : .off
        stopItem?.state = startsWithManager ? .off : .on
        proxyItem?.state = useProxy ? .on : .off
        monitorItem?.state = queueMonitor.isOpen ? .on : .off
        startItem?.isEnabled = !server.isBusy
        stopItem?.isEnabled = server.isBusy

        for item in [proxyPortItem, fixHistoryItem, issueReceiptItem, monitorItem, emptyQueueItem] {
            item?.isEnabled = useProxy
        }
    }

    private func cleanupBinFiles(modelsDir: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-3600)
            do {
                let items = try fm.contentsOfDirectory(atPath: modelsDir)
                var deletedCount = 0
                for item in items {

                    let isBinCandidate =
                        (item.hasPrefix("image-") || item.hasPrefix("mask-"))
                        && item.hasSuffix(".bin")
                    guard isBinCandidate else { continue }
                    let fullPath = (modelsDir as NSString).appendingPathComponent(item)
                    let attrs = try? fm.attributesOfItem(atPath: fullPath)
                    if let modDate = attrs?[.modificationDate] as? Date, modDate < cutoff {
                        do {
                            try fm.removeItem(atPath: fullPath)
                            deletedCount += 1
                            let msg = L10n.gcDeleted(item)
                            self.serverLog.append(msg)
                        } catch {
                            let msg = L10n.gcDeleteError(item, error.localizedDescription)
                            self.serverLog.append(msg)
                        }
                    }
                }
                if deletedCount > 0 {
                    let summary = L10n.gcSummary(deletedCount)
                    self.serverLog.append(summary)
                } else {
                    let summary = L10n.gcNoFiles
                    self.serverLog.append(summary)
                }
            } catch {
                let msg = L10n.gcScanError(modelsDir, error.localizedDescription)
                self.serverLog.append(msg)
            }
        }
    }

    private func startGCTimer(modelsDir: String) {
        stopGCTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 900, repeating: 900)
        timer.setEventHandler { [weak self] in
            self?.cleanupBinFiles(modelsDir: modelsDir)
        }
        gcTimer = timer
        timer.resume()
    }

    private func stopGCTimer() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {

        stopGCTimer()
        proxy.terminateNow()
        server.terminateNow()
    }
}
