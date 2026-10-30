import Foundation

enum KeyLocation {
    static var settingsURL: URL {
        if let path = ProcessInfo.processInfo.environment["ONEP_SETTINGS_PATH"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/1P备份助手/settings.plist")
    }

    static func resolve(settings: URL = settingsURL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment["SUPPORT_DIR"], !override.isEmpty {
            return try checkedPath(override)
        }
        guard FileManager.default.fileExists(atPath: settings.path) else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/1P备份")
        }
        let data = try Data(contentsOf: settings)
        guard let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let path = config["keyDirectory"] else {
            throw BackendFailure(code: 25, detail: "密钥位置设置损坏；不会自动改用其他密钥。请重新选择密钥目录。")
        }
        let directory = try checkedPath(path)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw BackendFailure(code: 25, detail: "保存的密钥目录不可用：\(path)")
        }
        return directory
    }

    static func checkedPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            throw BackendFailure(code: 25, detail: "密钥位置必须是绝对路径，且不能含换行符。")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func save(_ directory: URL, settings: URL = settingsURL) throws {
        let fm = FileManager.default
        try validateDirectory(directory)
        let parent = settings.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: ["keyDirectory": directory.path], format: .xml, options: 0)
        try data.write(to: settings, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }

    static func validateDirectory(_ directory: URL) throws {
        _ = try checkedPath(directory.path)
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw BackendFailure(code: 25, detail: "请选择实际文件夹，不要选择符号链接。")
        }
    }

    static func hasKeyFiles(_ directory: URL) -> Bool {
        ["private.key", "public.key"].contains {
            (try? directory.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey])) != nil
        }
    }

    static func copyKeys(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try validateDirectory(destination)
        var copied: [URL] = []
        do {
            for name in ["private.key", "public.key"] {
                let from = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                let values = try from.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true && values.isSymbolicLink != true else {
                    throw BackendFailure(code: 23, detail: "密钥必须是普通文件，不能是符号链接。")
                }
                let to = destination.appendingPathComponent(name)
                // copyItem fails if anything exists at the destination, including a link.
                try fm.copyItem(at: from, to: to)
                copied.append(to)
                try fm.setAttributes([.posixPermissions: name == "private.key" ? 0o600 : 0o644], ofItemAtPath: to.path)
            }
        } catch {
            // Roll back only files created by this call, never the source keys.
            for url in copied { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
