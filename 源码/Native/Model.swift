import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum Operation: String, CaseIterable, Identifiable {
    case encrypt, decrypt, verify
    var id: String { rawValue }
    var title: String {
        switch self { case .encrypt: "加密备份"; case .decrypt: "解密恢复"; case .verify: "校验备份" }
    }
    var symbol: String {
        switch self { case .encrypt: "lock"; case .decrypt: "lock.open"; case .verify: "checkmark.shield" }
    }
    var subtitle: String {
        switch self {
        case .encrypt: "给密码库一份独立、长久的备份。"
        case .decrypt: "用你保管的私钥，找回备份里的内容。"
        case .verify: "不用解密，检查备份是否与校验记录一致。"
        }
    }
    var dropTitle: String {
        switch self {
        case .encrypt: "把备份放进来，安心存起来。"
        case .decrypt: "你的备份，只有你的密钥能打开。"
        case .verify: "为存放已久的备份做一次体检。"
        }
    }
    var dropHint: String {
        self == .encrypt ? "拖入文件或整个文件夹，也可以手动选择" : "拖入 .age 文件，或从访达中选择"
    }
    var action: String {
        switch self { case .encrypt: "加密并生成校验文件"; case .decrypt: "解密到当前文件夹"; case .verify: "开始校验" }
    }
    var note: String {
        switch self {
        case .encrypt: "原文件不会自动删除。确认备份可恢复后，再清理明文。"
        case .decrypt: "解密后的文件含明文密码。完成导入后，请及时清理。"
        case .verify: "需要旁边的 .sha256 文件。校验通过不代表私钥可用。"
        }
    }
}

struct BackendReply: Sendable {
    let code: Int32
    let output: String
    var values: [String: String] { Self.parse(output) }
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            // Ignore arbitrary diagnostics; only the backend's documented fields are data.
            guard ["OK_PATH", "OK_SHA256", "HAS_KEY", "HAS_PRIV", "PUB", "SUPPORT",
                   "OK_PUB", "NOTE", "SELFTEST", "VERIFY", "SHA256", "OK_KIND", "KEY_PUB"].contains(key) else { continue }
            if result[key] == nil { result[key] = String(line[line.index(after: separator)...]) }
        }
        return result
    }
}

struct BackendFailure: LocalizedError, Sendable {
    let code: Int32
    let detail: String
    var errorDescription: String? {
        let message: String
        switch code {
        case 3: message = "还没有公钥。请先打开「密钥与恢复」，生成密钥或从已有私钥恢复公钥。"
        case 4: message = "目标文件或校验文件已存在，没有覆盖。请保留已有文件，改名或换到空文件夹后再试。"
        case 5: message = "加密失败。请检查输入文件、公钥和文件夹的写入权限。"
        case 6: message = "这不是有效的 age 加密文件，或者文件已经损坏。"
        case 7: message = "本机没有有效私钥。请将原来的 private.key 放回密钥文件夹。"
        case 8: message = "解密失败。私钥不匹配，或备份文件已损坏。未保存不完整的明文输出。"
        case 9: message = "私钥已经存在，程序不会覆盖它。请保留原私钥，它是恢复旧备份的关键。"
        case 11: message = "这个文件是空的，没有可加密的内容。"
        case 12: message = "公钥内容异常。请检查 public.key，或使用原私钥重新恢复公钥。"
        case 14: message = "解密自检未通过。请检查公钥与私钥是否配对。"
        case 16: message = "没有找到旁边的 .sha256 文件。请把密文与对应的校验文件放在同一文件夹。"
        case 17: message = "校验文件格式异常，无法读取有效的 SHA256 记录。"
        case 18: message = "文件与校验记录不一致，可能已损坏或被改动。请保留现有文件，并检查其他备份副本。"
        case 19: message = "这个文件已经是 age 密文，不需要再次加密。请切换到解密或校验。"
        case 20: message = "公钥还在，但私钥缺失。请先找回原私钥；新生成的密钥不能恢复旧备份。"
        case 21: message = "文件或校验记录未能完整保存。请勿删除原文件，检查空间与权限后换到空文件夹重试。"
        case 25: message = "密钥位置不可用。请接入磁盘或在「密钥与恢复」中更改位置；不会自动改用默认密钥。"
        case 26: message = "文件夹打包失败。请检查文件是否可读；不支持符号链接和特殊文件。"
        case 27: message = "文件夹归档损坏或包含不安全路径，已停止恢复。"
        case 28: message = "密钥文本操作未完成。"
        case 90, 91: message = "App 内部文件缺失，请恢复完整的 App。"
        default: message = "操作未完成（代码 \(code)）。"
        }
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? message : message + "\n\n" + String(clean.prefix(1600))
    }
}

enum Backend {
    static func run(_ command: String, file: URL? = nil, resources: URL? = nil,
                    support: String? = nil) async throws -> BackendReply {
        guard let directory = resources ?? Bundle.main.resourceURL else {
            throw BackendFailure(code: 90, detail: "找不到 App 资源目录。")
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [directory.appendingPathComponent("helper.sh").path, command]
                + (file.map { [$0.path] } ?? [])
            var environment = ProcessInfo.processInfo.environment
            if let support { environment["SUPPORT_DIR"] = support }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Drain while the process runs: waiting first can deadlock on a full pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let reply = BackendReply(code: process.terminationStatus,
                                     output: String(decoding: data, as: UTF8.self))
            guard reply.code == 0 else {
                throw BackendFailure(code: reply.code, detail: reply.output)
            }
            return reply
        }.value
    }
}

struct JobResult {
    let operation: Operation
    let file: URL
    let digest: String?
    var isFolder = false
}

enum Panel: String, Identifiable {
    case keys, guide
    var id: String { rawValue }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var operation: Operation = .encrypt
    @Published var selection: URL?
    @Published var result: JobResult?
    @Published var busy = false
    @Published var taskLabel = ""
    @Published var hasPublic = false
    @Published var hasPrivate = false
    @Published var publicKey = ""
    @Published var supportPath = ""
    @Published var panel: Panel?
    @Published var notice: Notice?
    @Published var selftestPassed = false
    @Published var keyFeedback: String?

    var selectionIsFolder: Bool {
        guard let selection else { return false }
        return (try? selection.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var canRun: Bool {
        guard selection != nil && !busy else { return false }
        switch operation {
        case .encrypt: return hasPublic
        case .decrypt: return hasPrivate
        case .verify: return true
        }
    }
    var keySummary: String {
        if hasPublic && hasPrivate { return "公钥与私钥已配置" }
        if hasPublic { return "仅公钥 · 可加密" }
        if hasPrivate { return "需要恢复公钥" }
        return "尚未配置密钥"
    }
    var fileSize: String {
        if selectionIsFolder { return "整个文件夹 · 包含子文件夹与隐藏文件" }
        guard let selection,
              let size = try? selection.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "本地文件" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func refresh() async {
        do {
            let directory = try KeyLocation.resolve()
            supportPath = directory.path
            guard !FileManager.default.fileExists(atPath: KeyLocation.settingsURL.path)
                    || ProcessInfo.processInfo.environment["SUPPORT_DIR"] != nil
                    || (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw BackendFailure(code: 25, detail: directory.path)
            }
            let values = try await Backend.run("status", support: directory.path).values
            hasPublic = values["HAS_KEY"] == "1"
            hasPrivate = values["HAS_PRIV"] == "1"
            publicKey = values["PUB"] ?? ""
            supportPath = values["SUPPORT"] ?? ""
        } catch {
            hasPublic = false; hasPrivate = false; publicKey = ""
            show(error)
        }
    }

    func changeOperation(_ next: Operation) {
        guard !busy else { return }
        operation = next
        selection = nil
        result = nil
    }

    func accept(_ urls: [URL], route: Bool = false) {
        guard !busy else {
            notice = Notice(title: "正在处理文件", message: "请等待当前任务完成，再添加下一个文件。")
            return
        }
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            notice = Notice(title: "请一次选择一项", message: "可以选择一个文件，或一个包含多个文件的文件夹。")
            return
        }
        let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        let isFolder = properties?.isDirectory == true
        let next = route ? (isFolder ? .encrypt : url.pathExtension.lowercased() == "age" ? .decrypt : .encrypt) : operation
        guard properties?.isSymbolicLink != true,
              properties?.isRegularFile == true || (isFolder && next == .encrypt) else {
            notice = Notice(title: "无法使用这个项目", message: "加密可选择普通文件或实际文件夹；解密和校验请选择 .age 文件，不接受符号链接。")
            return
        }
        guard !url.path.contains("\n") && !url.path.contains("\r") else {
            notice = Notice(title: "请先修改文件名", message: "文件路径不能含换行符。")
            return
        }
        operation = next
        selection = url
        result = nil
        panel = nil
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseFile() {
        guard !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = operation == .encrypt
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.prompt = operation == .encrypt ? "选择文件或文件夹" : "选择文件"
        picker.message = operation.dropHint
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
            notice = Notice(title: "无法打开文件选择器", message: "请重新打开主窗口后再试。")
            return
        }
        picker.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.accept(picker.urls) }
        }
    }

    func perform() {
        guard canRun, let file = selection else { return }
        let mode = operation
        busy = true
        taskLabel = mode == .encrypt ? (selectionIsFolder ? "正在打包文件夹、加密并生成校验记录…" : "正在加密并生成校验记录…") : mode == .decrypt ? "正在解密备份，文件夹归档将自动还原…" : "正在计算并核对 SHA256…"
        Task {
            defer { busy = false }
            do {
                let values = try await Backend.run(mode.rawValue, file: file, support: try KeyLocation.resolve().path).values
                let output: URL
                if mode == .verify {
                    guard values["VERIFY"] == "OK" else { throw BackendFailure(code: 17, detail: "后端没有返回校验成功标记。") }
                    output = file
                } else {
                    guard let path = values["OK_PATH"], path.hasPrefix("/"),
                          FileManager.default.fileExists(atPath: path) else {
                        throw BackendFailure(code: 21, detail: "后端没有返回有效的输出文件。")
                    }
                    output = URL(fileURLWithPath: path)
                }
                result = JobResult(operation: mode, file: output, digest: values["OK_SHA256"] ?? values["SHA256"], isFolder: values["OK_KIND"] == "folder")
            } catch { show(error) }
        }
    }

    func generateKeys() {
        guard !busy else { return }
        busy = true
        taskLabel = hasPrivate ? "正在恢复公钥…" : "正在生成密钥…"
        keyFeedback = nil
        Task {
            defer { busy = false }
            do {
                let reply = try await Backend.run("keygen", support: try KeyLocation.resolve().path)
                await refresh()
                keyFeedback = reply.values["NOTE"] ?? "密钥已生成。请立即备份 private.key，并单独保管恢复口令。"
                selftestPassed = false
            } catch { show(error) }
        }
    }

    func selftest() {
        guard !busy else { return }
        busy = true
        taskLabel = "正在验证密钥与加解密链路…"
        keyFeedback = nil
        Task {
            defer { busy = false }
            do {
                let reply = try await Backend.run("selftest", support: try KeyLocation.resolve().path)
                guard reply.values["SELFTEST"] == "OK" else { throw BackendFailure(code: 15, detail: "未返回自检成功标记。") }
                selftestPassed = true
                keyFeedback = "自检通过：本机公私钥配对，加解密链路可用。仍建议用真实备份做一次恢复演练。"
            } catch { selftestPassed = false; show(error) }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func chooseKeyLocation() {
        guard !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "使用此密钥文件夹"
        picker.message = "请选择专用密钥文件夹。不会移动、覆盖或删除原有密钥；外置磁盘需保持连接。"
        if !supportPath.isEmpty { picker.directoryURL = URL(fileURLWithPath: supportPath).deletingLastPathComponent() }
        guard var window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        while let sheet = window.attachedSheet { window = sheet }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = picker.url else { return }
            // Wait until the file panel detaches, then present on the original
            // key sheet rather than NSApp.keyWindow (which may be the main window).
            DispatchQueue.main.async { self?.confirmKeyLocation(target, presenter: window) }
        }
    }

    private func confirmKeyLocation(_ target: URL, presenter: NSWindow) {
        guard !busy else { return }
        let current = try? KeyLocation.resolve()
        if target.standardizedFileURL == current?.standardizedFileURL { return }
        let hasKeys = KeyLocation.hasKeyFiles(target)
        let canCopy = current.map(KeyLocation.hasKeyFiles) ?? false
        let alert = NSAlert()
        alert.messageText = hasKeys ? "使用所选位置的密钥？" : canCopy ? "将现有密钥复制到新位置？" : "更改密钥保存位置？"
        alert.informativeText = "新位置：\(target.path)\n\n" + (hasKeys
            ? "将先检查这里的密钥是否有效。不会覆盖此处密钥；如果与原密钥不同，旧备份仍需用原私钥恢复。原位置保留。"
            : canCopy ? "把现有 public.key / private.key 复制到这里，成功后切换。原件保留，密钥本身不变。请避免将明文私钥放入云同步目录。"
            : "后续生成的密钥将放在这里；此操作不会自动生成新密钥。请避免云同步目录，且不要把外置磁盘当作唯一私钥副本。")
        alert.addButton(withTitle: hasKeys ? "检查并使用" : canCopy ? "复制并切换" : "使用此位置")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: presenter) { [weak self] answer in
            guard answer == .alertFirstButtonReturn else { return }
            self?.switchKeyLocation(to: target, copyFrom: !hasKeys && canCopy ? current : nil)
        }
    }

    private func switchKeyLocation(to target: URL, copyFrom source: URL?) {
        busy = true
        taskLabel = source == nil ? "正在检查新密钥位置…" : "正在复制密钥并检查新位置…"
        Task {
            defer { busy = false }
            do {
                try KeyLocation.validateDirectory(target)
                _ = try await Backend.run("checkkeys", support: target.path)
                if let source {
                    _ = try await Backend.run("checkkeys", support: source.path)
                    try KeyLocation.copyKeys(from: source, to: target)
                    _ = try await Backend.run("checkkeys", support: target.path)
                }
                try KeyLocation.save(target)
                // A SUPPORT_DIR override is for isolated tests; normal launches use the saved config.
                await refresh()
                selftestPassed = false
                keyFeedback = "密钥位置已保存。原位置的密钥没有移动或删除。若切换到不同密钥，请保留旧私钥以恢复旧备份。"
            } catch { show(error) }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private var keyPresenter: NSWindow? {
        guard var window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        while let sheet = window.attachedSheet { window = sheet }
        return window
    }

    func exportKeyText(privateKey: Bool) {
        guard !busy, let window = keyPresenter else { return }
        if privateKey {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出未加密的私钥文本？"
            alert.informativeText = "拿到这个 .txt 文件的人可以解密你的备份，不需要 1Password 主密码。请勿保存到云同步或共享目录；打印时使用可信打印机。导出不会删除原私钥。"
            alert.addButton(withTitle: "继续导出私钥")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] answer in
                if answer == .alertFirstButtonReturn {
                    DispatchQueue.main.async { self?.saveKeyText(privateKey: true, presenter: window) }
                }
            }
        } else { saveKeyText(privateKey: false, presenter: window) }
    }

    private func saveKeyText(privateKey: Bool, presenter: NSWindow) {
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.plainText]
        picker.nameFieldStringValue = privateKey ? "age-private-key.txt" : "age-public-key.txt"
        picker.message = "UTF-8 纯文本，可用于打印或重新导入。请选择新文件名，不覆盖已有文件。"
        picker.beginSheetModal(for: presenter) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            self.busy = true
            self.taskLabel = "正在校验并导出密钥文本…"
            Task {
                defer { self.busy = false }
                do {
                    try await KeyTransfer.export(from: KeyLocation.resolve(), privateKey: privateKey, to: url)
                    self.keyFeedback = privateKey ? "私钥 .txt 已导出，这是未加密的秘密文件。请安全保管并验证可重新导入。" : "公钥 .txt 已导出，可公开，也可重新导入。"
                } catch { self.show(error) }
            }
        }
    }

    func importKeyText() {
        guard !busy, let window = keyPresenter else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.prompt = "识别密钥文本"
        picker.message = "选择 .txt 或 .key 纯文本；自动识别 age 公钥或私钥。不会根据扩展名盲目导入。"
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = picker.url, let self else { return }
            self.busy = true
            self.taskLabel = "正在识别并校验密钥文本…"
            Task {
                do {
                    let key = try await KeyTransfer.validate(KeyTransfer.readText(url))
                    self.busy = false
                    DispatchQueue.main.async { self.confirmImport(key, presenter: window) }
                } catch { self.busy = false; self.show(error) }
            }
        }
    }

    private func confirmImport(_ key: ValidatedKeyText, presenter: NSWindow) {
        let directory: URL
        do { directory = try KeyLocation.resolve() } catch { show(error); return }
        let alert = NSAlert()
        alert.messageText = key.privateKey == nil ? "识别到有效公钥" : "识别到有效私钥"
        alert.informativeText = "对应公钥：\(key.publicKey)\n\n导入位置：\(directory.path)\n\n" + (key.privateKey == nil
            ? "公钥仅能加密，不能恢复备份。不同的现有密钥不会被覆盖。"
            : "将恢复 private.key，并自动生成对应 public.key。不同的现有密钥不会被覆盖；私钥内容不会在界面展示。")
        alert.addButton(withTitle: "确认导入")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: presenter) { [weak self] answer in
            guard answer == .alertFirstButtonReturn, let self else { return }
            self.busy = true
            self.taskLabel = "正在安全导入密钥…"
            Task {
                defer { self.busy = false }
                do {
                    try await KeyTransfer.install(key, into: directory)
                    await self.refresh()
                    self.selftestPassed = false
                    self.keyFeedback = key.privateKey == nil ? "公钥已导入；只有公钥不能解密。相同的现有密钥保持不变。" : "私钥已导入，对应公钥已恢复。请运行自检，并试解密一份旧备份。"
                } catch { self.show(error) }
            }
        }
    }

    func show(_ error: Error) {
        notice = Notice(title: "操作未完成", message: error.localizedDescription)
    }
}
