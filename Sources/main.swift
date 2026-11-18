/**
 * DSH Web Launcher — 一个很小的 macOS 原生壳。
 *
 * 做三件事：
 *  1. 启动时把 `dsh web --no-open --host 127.0.0.1 --port 0` 当子进程跑起来；
 *  2. 从它的 stdout 里取带 token 的 URL，用 WKWebView 打开；
 *  3. 关窗或退出 App 时，先 SIGTERM 让 host 优雅收尾，超时再 SIGKILL。
 *
 * 不用 Electron：界面走系统 WebKit，App 本体只有几百 KB。
 */

import Cocoa
import WebKit
import Darwin

// MARK: - 路径与日志

let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let logFileURL = homeDirectory.appendingPathComponent("Library/Logs/DSH Web Launcher.log")
let configFileURL = homeDirectory.appendingPathComponent(".dsh/web-launcher.json")

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let manager = FileManager.default
    if manager.fileExists(atPath: logFileURL.path) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: logFileURL)
    }
}

// MARK: - 配置

struct LauncherConfig: Codable {
    var node: String
    var cli: String
    var cwd: String
    var host: String
    var port: Int
    var extraArgs: [String]
    var env: [String: String]

    init(node: String, cli: String, cwd: String, host: String, port: Int, extraArgs: [String], env: [String: String] = [:]) {
        self.node = node
        self.cli = cli
        self.cwd = cwd
        self.host = host
        self.port = port
        self.extraArgs = extraArgs
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decodeIfPresent(String.self, forKey: .node) ?? ""
        cli = try container.decodeIfPresent(String.self, forKey: .cli) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        extraArgs = try container.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

func resolveNodePath() -> String {
    if let explicit = ProcessInfo.processInfo.environment["DSH_LAUNCHER_NODE"], !explicit.isEmpty {
        return explicit
    }
    for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "command -v node"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return path }
    } catch {
        logLine("node 查找失败：\(error)")
    }
    return "node"
}

func resolveCLIPath() -> String {
    if let explicit = ProcessInfo.processInfo.environment["DSH_LAUNCHER_CLI"], !explicit.isEmpty {
        return explicit
    }
    let candidates = [
        homeDirectory.appendingPathComponent("Code/deepseek-harness/apps/cli/lib/bin.js").path,
        homeDirectory.appendingPathComponent(".dsh/web/bin.js").path,
    ]
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    return ""
}

func loginShellPath() -> String {
    if let existing = ProcessInfo.processInfo.environment["PATH"], existing.contains("/opt/homebrew/bin") {
        return existing
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "print -r -- $PATH"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func resolveWorkingDirectory() -> String {
    homeDirectory.path
}

func expandedPath(_ path: String) -> String {
    path.isEmpty ? path : (path as NSString).expandingTildeInPath
}

func loadConfiguration() -> LauncherConfig {
    let fallback = LauncherConfig(
        node: resolveNodePath(),
        cli: resolveCLIPath(),
        cwd: resolveWorkingDirectory(),
        host: "127.0.0.1",
        port: 3080,
        extraArgs: []
    )
    guard let data = try? Data(contentsOf: configFileURL),
          var decoded = try? JSONDecoder().decode(LauncherConfig.self, from: data) else {
        saveConfiguration(fallback)
        return fallback
    }
    decoded.node = expandedPath(decoded.node)
    decoded.cli = expandedPath(decoded.cli)
    decoded.cwd = expandedPath(decoded.cwd)
    if decoded.node.isEmpty { decoded.node = fallback.node }
    if decoded.cli.isEmpty { decoded.cli = fallback.cli }
    if decoded.cwd.isEmpty { decoded.cwd = fallback.cwd }
    if decoded.host.isEmpty { decoded.host = "127.0.0.1" }
    if let raw = ProcessInfo.processInfo.environment["DSH_LAUNCHER_PORT"], let value = Int(raw) {
        decoded.port = value
    }
    return decoded
}

func saveConfiguration(_ config: LauncherConfig) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(config) else { return }
    try? FileManager.default.createDirectory(
        at: configFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? data.write(to: configFileURL)
}

// MARK: - host 子进程

enum LauncherError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

final class HostServer {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrTail = ""
    private var ready = false
    private var stopping = false

    var onReady: ((URL) -> Void)?
    var onUnexpectedExit: ((String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(config: LauncherConfig) throws {
        ready = false
        stdoutBuffer = ""
        stderrTail = ""
        stopping = false
        guard FileManager.default.isExecutableFile(atPath: config.node) else {
            throw LauncherError.message("找不到 node：\(config.node)\n\n修改配置文件：\(configFileURL.path)")
        }
        guard FileManager.default.fileExists(atPath: config.cli) else {
            throw LauncherError.message("找不到 dsh CLI：\(config.cli)\n\n修改配置文件：\(configFileURL.path)")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.node)
        child.arguments = [config.cli, "web", "--no-open", "--host", config.host, "--port", String(config.port)]
            + config.extraArgs
        child.currentDirectoryURL = URL(fileURLWithPath: config.cwd, isDirectory: true)

        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = URL(fileURLWithPath: config.node).deletingLastPathComponent().path
        let shellPath = loginShellPath()
        let basePath = shellPath.isEmpty
            ? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            : shellPath
        environment["PATH"] = nodeDirectory + ":" + basePath
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        // 告诉 dsh-version-check：升级完别自己 nohup 起新 host，交给启动器重启。
        environment["DSH_LAUNCHER"] = "1"
        for (key, value) in config.env {
            environment[key] = value
        }
        child.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        child.standardOutput = stdout
        child.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(stdout: text) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(stderr: text) }
        }
        child.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async { self?.handleExit(exited) }
        }

        try child.run()
        process = child
        logLine("host 启动 pid=\(child.processIdentifier) cwd=\(config.cwd)")
    }

    private func consume(stdout text: String) {
        stdoutBuffer += text
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newline])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            handleLine(line)
        }
        if stdoutBuffer.count > 16_384 {
            stdoutBuffer = String(stdoutBuffer.suffix(4_096))
        }
    }

    private func handleLine(_ line: String) {
        logLine("host: \(line)")
        guard !ready, let marker = line.range(of: "dsh web: ") else { return }
        let raw = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme != nil else { return }
        ready = true
        onReady?(url)
    }

    private func consume(stderr text: String) {
        stderrTail += text
        if stderrTail.count > 12_000 {
            stderrTail = String(stderrTail.suffix(6_000))
        }
        logLine("host stderr: \(text.trimmingCharacters(in: .newlines))")
    }

    private func handleExit(_ exited: Process) {
        logLine("host 退出 status=\(exited.terminationStatus) reason=\(exited.terminationReason.rawValue)")
        guard !stopping else { return }
        let detail = ready
            ? "服务进程意外退出。\n\n" + stderrTail
            : "服务没有起来。\n\n" + stderrTail
        onUnexpectedExit?(detail)
    }

    func stop(timeout: TimeInterval = 7) {
        guard let child = process else { return }
        let finished = DispatchSemaphore(value: 0)
        stopping = true
        defer {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stdoutPipe = nil
            stderrPipe = nil
            process = nil
            stopping = false
        }
        guard child.isRunning else {
            logLine("host 已经退出")
            return
        }
        child.terminationHandler = { _ in finished.signal() }
        logLine("停止 host pid=\(child.processIdentifier)（SIGTERM）")
        child.terminate()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            logLine("host \(Int(timeout)) 秒未退出，SIGKILL")
            kill(child.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
        }
        logLine("host 已停止")
    }
}

/// 窗口不在前台时，第一次点击也交给网页里的控件。默认实现只拿这次点击激活窗口，
/// 用户看到的就是按钮要点两下才响应。
final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 网页容器不是第一响应者时，WebKit 会拿第一次 mouseDown 去聚焦，
    /// 页面收不到这次点击。先把焦点拿到手，再交给 WebKit 处理。
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let server = HostServer()
    private var config = LauncherConfig(node: "", cli: "", cwd: "", host: "127.0.0.1", port: 3080, extraArgs: [])
    private var window: NSWindow!
    private var webView: WKWebView!
    private var appPort: Int?
    private var titleObservation: NSKeyValueObservation?
    private var launchURL: URL?
    private var startupTimeout: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var clickMonitor: Any?
    private var pendingClickDown: NSEvent?
    private var pendingClickUp: NSEvent?
    private var awaitingFirstClick = true
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = loadConfiguration()
        installSignalHandlers()
        buildMenu()
        buildWindow()
        beginHost()
        installClickReplay()
    }

    /// 应用不在前台时，第一次点击只用来激活窗口，网页收不到。
    /// 这里先吞掉这次按下，激活窗口，再把按下和抬起重新交给 WebView。
    private func installClickReplay() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.replayClick(event)
        }
    }

    private func replayClick(_ event: NSEvent) -> NSEvent? {
        guard let window, let contentView = window.contentView, event.window === window else { return event }
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        guard contentView.frame.contains(event.locationInWindow) else { return event }
        switch event.type {
        case .leftMouseDown:
            // 标题栏上的点击交给系统处理，也不清「首次点击」标记：
            // 点标题栏激活窗口之后，下一次点内容仍然需要重放。
            guard contentView.frame.contains(event.locationInWindow) else { return event }
            let needsFocus = window.firstResponder !== webView
            guard awaitingFirstClick || needsFocus else { return event }
            awaitingFirstClick = false
            pendingClickDown = event
            pendingClickUp = nil
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            logLine("首次点击重放，位置 \(event.locationInWindow)")
            scheduleClickReplay()
            return nil
        case .leftMouseUp:
            guard pendingClickDown != nil else { return event }
            pendingClickUp = event
            return nil
        default:
            return event
        }
    }

    private func scheduleClickReplay(attempt: Int = 0) {
        guard let window, let webView, let down = pendingClickDown else { return }
        guard attempt < 100 else {
            pendingClickDown = nil
            pendingClickUp = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pendingClickDown != nil else { return }
            guard NSApp.isActive, window.isKeyWindow else {
                self.scheduleClickReplay(attempt: attempt + 1)
                return
            }
            window.makeFirstResponder(webView)
            // 激活后再等一小会儿，给 WebKit 的 web 进程恢复焦点的时间。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let cssX = down.locationInWindow.x
                let cssY = webView.bounds.height - down.locationInWindow.y
                let js = """
                (function(){
                  var el = document.elementFromPoint(\(cssX), \(cssY));
                  if (!el) return 'nil';
                  el.click();
                  return el.tagName + '|' + (el.textContent || '').slice(0, 30);
                })()
                """
                webView.evaluateJavaScript(js) { value, error in
                    logLine("JS点击: \(value ?? error.map { "\($0)" } ?? "nil")")
                    self.pendingClickDown = nil
                    self.pendingClickUp = nil
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureWebFocus()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ensureWebFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        awaitingFirstClick = true
    }

    private func ensureWebFocus() {
        guard let window, let webView else { return }
        // 端口冲突提示之类的模态窗口在前台时不要抢焦点。
        guard window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        guard window.firstResponder !== webView else { return }
        window.makeFirstResponder(webView)
    }

    /// 让 `kill -TERM` 也走 AppKit 的正常退出路径，触发 host 收尾。
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                logLine("收到信号 \(signalNumber)，退出")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: 窗口

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSH Web"
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("DSHWebLauncherWindow")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = ClickThroughWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        window.contentView = webView
        // 先拿住第一响应者：否则回前台后的第一次点击会被网页容器拿去聚焦，不落到按钮上。
        window.initialFirstResponder = webView
        window.makeFirstResponder(webView)

        if window.setFrameUsingName("DSHWebLauncherWindow") == false {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let pageTitle = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logLine("页面标题: \(pageTitle)")
                self.window.title = pageTitle.isEmpty ? "DSH Web" : "DSH Web · \(pageTitle)"
            }
        }

        webView.loadHTMLString(Self.loadingHTML, baseURL: nil)
    }

    /// 起一次 host。首次启动和升级构建完成后都走这里。
    private func beginHost() {
        startupTimeout?.cancel()
        startupTimeout = nil
        appPort = nil
        launchURL = nil
        server.onReady = { [weak self] url in
            guard let self else { return }
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            self.appPort = url.port
            self.launchURL = url
            logLine("打开 \(url.absoluteString)")
            self.webView.load(URLRequest(url: url))
        }
        server.onUnexpectedExit = { [weak self] detail in
            guard let self else { return }
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            if self.isUpgradeRunning() {
                self.beginUpgradeWait()
            } else {
                self.showError(title: "DSH 启动失败", detail: detail)
            }
        }
        promptPortIfNeeded()
    }

    /// 端口被占用时先问用户：是不是停掉占用它的 dsh web，再起自己的 host。
    /// 只对命令行看起来像 dsh web 的进程提供「停止并启动」；其它进程不动。
    private func promptPortIfNeeded() {
        guard config.port > 0, !isTerminating else {
            startHostProcess()
            return
        }
        let pids = listeningPIDs()
        guard !pids.isEmpty else {
            startHostProcess()
            return
        }
        let pid = pids[0]
        let command = commandLine(of: pid)
        let dsh = looksLikeDSHWeb(command)
        let shownCommand = command.count > 240 ? String(command.prefix(240)) + "…" : command
        logLine("端口 \(config.port) 被占用：pid=\(pid) command=\(command)")

        let alert = NSAlert()
        alert.messageText = "端口 \(config.port) 已被占用"
        if dsh {
            alert.informativeText = "占用进程：PID \(pid)\n\(shownCommand)\n\n停掉它，用启动器重新启动 DSH 吗？"
            alert.addButton(withTitle: "停止并启动")
            alert.addButton(withTitle: "取消")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = "\u{1b}"
        } else {
            alert.informativeText = "占用进程：PID \(pid)\n\(shownCommand)\n\n看起来不是 dsh web，启动器不会动它。请手动处理后重新打开。"
            alert.addButton(withTitle: "好")
            alert.buttons[0].keyEquivalent = "\r"
        }

        let response = alert.runModal()
        if dsh {
            if response == .alertFirstButtonReturn {
                stopProcessesAndStart(pids)
            } else {
                showError(title: "已取消启动", detail: "端口 \(config.port) 仍被 PID \(pid) 占用，没有启动新的 host。")
            }
        } else {
            showError(title: "端口被占用", detail: "端口 \(config.port) 被 PID \(pid) 占用：\n\(command)")
        }
    }

    private func startHostProcess() {
        do {
            try server.start(config: config)
        } catch {
            showError(title: "DSH 启动失败", detail: error.localizedDescription)
            return
        }
        armStartupTimeout()
    }

    /// 先 SIGTERM，最多等 8 秒；不退再 SIGKILL，最后确认端口真的空出来。
    private func stopProcessesAndStart(_ pids: [Int32]) {
        webView.loadHTMLString(Self.loadingHTML, baseURL: nil)
        logLine("停掉占用 \(config.port) 的进程：\(pids.map(String.init).joined(separator: ","))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for pid in pids {
                _ = kill(pid, SIGTERM)
            }
            var free = self.waitForPortFree(timeout: 8)
            if !free {
                let remaining = self.listeningPIDs()
                for pid in remaining {
                    _ = kill(pid, SIGKILL)
                }
                logLine("SIGTERM 没退，SIGKILL：\(remaining.map(String.init).joined(separator: ","))")
                free = self.waitForPortFree(timeout: 3)
            }
            let still = free ? [] : self.listeningPIDs()
            DispatchQueue.main.async {
                if free {
                    logLine("端口 \(self.config.port) 已释放，启动 host")
                    self.startHostProcess()
                } else {
                    self.showError(
                        title: "端口没有释放",
                        detail: "停掉占用进程后 \(self.config.port) 仍被占用：\(still.map(String.init).joined(separator: ", "))。手动处理后重新打开。"
                    )
                }
            }
        }
    }

    private func waitForPortFree(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listeningPIDs().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return listeningPIDs().isEmpty
    }

    private func listeningPIDs() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(config.port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func commandLine(of pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "(读不到命令)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeDSHWeb(_ command: String) -> Bool {
        let lower = command.lowercased()
        let hasWeb = lower.contains(" web") || lower.hasSuffix("web")
        guard hasWeb else { return false }
        return lower.contains("bin.js") || lower.contains("dsh")
    }

    private func armStartupTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.launchURL == nil, !self.isTerminating else { return }
            self.server.stop()
            self.showError(
                title: "DSH 启动超时",
                detail: "60 秒内没有等到服务 URL，已经停止这次启动的 host。\n\n可以把 ~/.dsh/web-launcher.json 里的 cli 指到正确的 apps/cli/lib/bin.js。"
            )
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    // MARK: 升级

    private var dshHomePath: String {
        if let value = config.env["DSH_HOME"], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment["DSH_HOME"], !value.isEmpty { return value }
        return homeDirectory.appendingPathComponent(".dsh").path
    }

    private var upgradeLockURL: URL {
        URL(fileURLWithPath: dshHomePath)
            .appendingPathComponent("state/dsh-version-check/upgrade/building")
    }

    private func isUpgradeRunning() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: upgradeLockURL.path) else { return false }
        // 只认最近写过的锁；没人清的老锁不该让启动器一直等。
        guard let attributes = try? manager.attributesOfItem(atPath: upgradeLockURL.path),
              let modified = attributes[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) < 2 * 60 * 60
    }

    private func beginUpgradeWait() {
        logLine("检测到升级构建锁：\(upgradeLockURL.path)")
        webView.loadHTMLString(Self.upgradingHTML, baseURL: nil)
        pollForUpgrade(deadline: Date().addingTimeInterval(30 * 60))
    }

    private func pollForUpgrade(deadline: Date) {
        guard !isTerminating else { return }
        if !isUpgradeRunning() {
            logLine("升级构建结束，重启 host")
            webView.loadHTMLString(Self.loadingHTML, baseURL: nil)
            beginHost()
            return
        }
        if Date() > deadline {
            showError(
                title: "DSH 升级等待超时",
                detail: "30 分钟内没有等到构建锁释放。构建可能失败了，看看 \(upgradeLockURL.deletingLastPathComponent().path) 里的 output.log。"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.pollForUpgrade(deadline: deadline)
        }
    }

    // MARK: 退出

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        if isUpgradeRunning() {
            logLine("升级构建中退出：构建会继续，但不会再起 host")
        }
        guard server.isRunning else { return .terminateNow }
        logLine("准备退出，停止服务")
        // 同步停：窗口已经要关了，这里多等几百毫秒比异步 reply 的时序问题可靠。
        server.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    func windowWillClose(_ notification: Notification) {
        logLine("窗口关闭")
    }

    // MARK: 菜单与动作

    private func buildMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: "关于 DSH Web",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "隐藏 DSH Web",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(
            withTitle: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "退出 DSH Web",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "重新载入", action: #selector(reloadPage), keyEquivalent: "r")
        let browserItem = viewMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "R")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openInBrowser() {
        // 走带 token 的原始 URL：默认浏览器没有 WKWebView 的 cookie，直接开当前
        // 地址会被 401 拦掉；token URL 会先铸一次 cookie 再跳转。
        guard let url = launchURL ?? webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }

    // MARK: 导航

    private func isAppURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["about", "blob", "data"].contains(scheme) { return true }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else { return false }
        if let port = url.port, let appPort { return port == appPort }
        return true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if isAppURL(url) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
            return
        }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            logLine("外部链接交给系统浏览器：\(url.absoluteString)")
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logLine("WebKit 内容进程结束，重新载入")
        webView.reload()
    }

    // MARK: 下载

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDirectory
        let proposed = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var destination = directory.appendingPathComponent(proposed)
        let base = (proposed as NSString).deletingPathExtension
        let fileExtension = (proposed as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = fileExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(fileExtension)"
            destination = directory.appendingPathComponent(name)
            counter += 1
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        logLine("下载完成")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        logLine("下载失败：\(error)")
    }

    // MARK: 弹窗与脚本对话框

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isAppURL(url) {
            NSWorkspace.shared.open(url)
        } else if let url = navigationAction.request.url {
            logLine("忽略页内新窗口：\(url.absoluteString)")
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: 错误页

    private func showError(title: String, detail: String) {
        var detail = detail
        if detail.contains("EADDRINUSE") {
            detail += "\n\n端口 \(config.port) 已经被占用：可能已经有一个 dsh web 在跑。\n先停掉它（终端里 Ctrl+C）再启动这个 App。两个 host 会抢同一份会话存储。"
        }
        logLine("错误：\(title)\n\(detail)")
        guard webView != nil else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        webView.loadHTMLString(Self.errorHTML(title: title, detail: detail), baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let upgradingHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <title>正在升级</title>
    <style>
      html, body { height: 100%; margin: 0; }
      body {
        display: flex; align-items: center; justify-content: center;
        background: #f7f7f8; color: #5f6368;
        font: 13px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      }
      @media (prefers-color-scheme: dark) {
        body { background: #161618; color: #a1a1a6; }
      }
      .box { display: flex; flex-direction: column; align-items: center; gap: 14px; text-align: center; }
      .sub { font-size: 12px; color: #8a8a8e; }
      .spinner {
        width: 22px; height: 22px; border-radius: 50%;
        border: 2px solid rgba(128, 128, 128, 0.25);
        border-top-color: rgba(128, 128, 128, 0.8);
        animation: spin 0.8s linear infinite;
      }
      @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    </head>
    <body><div class="box"><div class="spinner"></div><div>DSH 正在升级</div><div class="sub">构建完成后会自动重启，通常需要几分钟</div></div></body>
    </html>
    """

    private static let loadingHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <style>
      html, body { height: 100%; margin: 0; }
      body {
        display: flex; align-items: center; justify-content: center;
        background: #f7f7f8; color: #5f6368;
        font: 13px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      }
      @media (prefers-color-scheme: dark) {
        body { background: #161618; color: #a1a1a6; }
      }
      .box { display: flex; flex-direction: column; align-items: center; gap: 14px; }
      .spinner {
        width: 22px; height: 22px; border-radius: 50%;
        border: 2px solid rgba(128, 128, 128, 0.25);
        border-top-color: rgba(128, 128, 128, 0.8);
        animation: spin 0.8s linear infinite;
      }
      @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    </head>
    <body><div class="box"><div class="spinner"></div><div>正在启动 DSH…</div></div></body>
    </html>
    """

    private static func errorHTML(title: String, detail: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <style>
          html, body { height: 100%; margin: 0; }
          body {
            display: flex; align-items: center; justify-content: center;
            background: #f7f7f8; color: #333;
            font: 13px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #161618; color: #d1d1d6; }
          }
          .card { max-width: 680px; padding: 28px 32px; }
          h1 { margin: 0 0 12px; font-size: 18px; font-weight: 600; }
          pre {
            margin: 0 0 16px; padding: 12px 14px; overflow: auto; white-space: pre-wrap;
            word-break: break-word; border-radius: 8px; background: rgba(128, 128, 128, 0.12);
            font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          p { margin: 0; color: #6b7280; }
          code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        </style>
        </head>
        <body><div class="card">
          <h1>\(escape(title))</h1>
          <pre>\(escape(detail))</pre>
          <p>配置文件：<code>\(escape(configFileURL.path))</code><br>日志：<code>\(escape(logFileURL.path))</code></p>
        </div></body>
        </html>
        """
    }
}

// MARK: - 入口

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
