import Darwin
import Foundation

struct ValidatedKeyText: Sendable {
    let publicKey: String
    let privateKey: String?
}

enum KeyTransfer {
    static func failure(_ message: String) -> BackendFailure {
        BackendFailure(code: 28, detail: message)
    }

    static func readText(_ file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 65536 else {
            throw failure("请选择不超过 64 KB 的普通 UTF-8 文本文件，不接受符号链接。")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
            throw failure("无法读取 UTF-8 纯文本密钥；请勿使用 Word、RTF 或扫描图片。")
        }
        return text
    }

    static func validate(_ text: String, resources: URL? = nil) async throws -> ValidatedKeyText {
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var publicKey: String?
        var privateKey: String?
        for raw in normalized.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("AGE-SECRET-KEY-1"), privateKey == nil {
                privateKey = line
            } else if line.hasPrefix("age1"), publicKey == nil {
                publicKey = line
            } else {
                throw failure("文本含无法识别的内容或多把密钥。请保留一把 age 私钥、公钥（可选）及 # 注释，不要手动折行。")
            }
        }
        guard publicKey != nil || privateKey != nil else { throw failure("未找到 age 公钥或私钥。") }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("1p-key-check-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        if let privateKey { try writeExclusive(Data((privateKey + "\n").utf8), to: staging.appendingPathComponent("private.key")) }
        if let publicKey { try writeExclusive(Data((publicKey + "\n").utf8), to: staging.appendingPathComponent("public.key")) }
        let reply: BackendReply
        do { reply = try await Backend.run("checkkeys", resources: resources, support: staging.path) }
        catch {
            // Never echo validator diagnostics: malformed private-key text is sensitive.
            throw failure("密钥校验失败：内容不完整、校验码错误，或公私钥不配对。原有密钥没有改动。")
        }
        guard let derived = reply.values["KEY_PUB"], derived.hasPrefix("age1") else {
            throw failure("未能确定有效公钥。")
        }
        return ValidatedKeyText(publicKey: derived, privateKey: privateKey)
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("目标已存在或不可写，没有覆盖。请选择新的文件名：\(url.lastPathComponent)") }
        var success = false
        defer { close(fd); if !success { unlink(url.path) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("写入失败，请检查剩余空间；未保存不完整的文本文件。") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("无法完成文件写入，请检查磁盘。") }
        success = true
    }

    static func export(from directory: URL, privateKey: Bool, to destination: URL, resources: URL? = nil) async throws {
        let source = directory.appendingPathComponent(privateKey ? "private.key" : "public.key")
        let key = try await validate(readText(source), resources: resources)
        let text: String
        if privateKey {
            guard let secret = key.privateKey else { throw failure("源文件不是有效私钥。") }
            text = "# age private key - KEEP SECRET. Anyone with this key can decrypt your backups.\n# public key: \(key.publicKey)\n\(secret)\n"
        } else {
            text = "# age public key - safe to share. Cannot decrypt backups.\n\(key.publicKey)\n"
        }
        try writeExclusive(Data(text.utf8), to: destination)
    }

    static func install(_ key: ValidatedKeyText, into directory: URL, resources: URL? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try KeyLocation.validateDirectory(directory)
        let lock = directory.appendingPathComponent(".keygen.1p-lock")
        guard mkdir(lock.path, 0o700) == 0 else { throw failure("密钥目录正在使用或不可写，请稍后再试。") }
        defer { rmdir(lock.path) }
        let pub = directory.appendingPathComponent("public.key")
        let priv = directory.appendingPathComponent("private.key")
        var hasPub = false
        var hasPriv = false
        for (url, isPrivate) in [(pub, false), (priv, true)] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let existing = try await validate(readText(url), resources: resources)
                guard existing.publicKey == key.publicKey,
                      !isPrivate || existing.privateKey != nil else {
                    throw failure("导入的密钥与当前目录不同，已拒绝覆盖。请先更改到一个空密钥目录，再导入；旧备份仍需原私钥。")
                }
                if isPrivate { hasPriv = true } else { hasPub = true }
            } else if errno != ENOENT {
                throw failure("无法检查现有密钥，已停止导入。")
            }
        }
        var created: [URL] = []
        do {
            if let secret = key.privateKey, !hasPriv {
                try writeExclusive(Data(("# public key: \(key.publicKey)\n\(secret)\n").utf8), to: priv)
                created.append(priv)
            }
            if !hasPub {
                try writeExclusive(Data((key.publicKey + "\n").utf8), to: pub)
                created.append(pub)
            }
        } catch {
            for file in created { try? fm.removeItem(at: file) }
            throw error
        }
    }
}
