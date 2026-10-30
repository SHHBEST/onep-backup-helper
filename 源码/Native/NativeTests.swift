import AppKit
import Foundation

@main
struct NativeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "NativeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("1p-native-tests-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let support = tmp.appendingPathComponent("keys").path
        func run(_ command: String, _ file: URL? = nil) async throws -> BackendReply {
            try await Backend.run(command, file: file, resources: root, support: support)
        }
        let parsed = BackendReply.parse("diagnostic=a\nOK_PATH=/tmp/a=b.age\nOK_SHA256=abc\nOK_PATH=/tmp/no\n")
        try expect(parsed["OK_PATH"] == "/tmp/a=b.age", "Protocol parsing must preserve '=' and first value")
        try expect(parsed["diagnostic"] == nil, "Unknown fields must not be data")
        for symbol in ["lock", "lock.open", "checkmark.shield", "lock.shield", "lock.shield.fill",
                       "network.slash", "circle.lefthalf.filled", "lock.fill", "lock.open.fill",
                       "checkmark.shield.fill", "doc.zipper", "lock.doc", "checkmark.seal.fill",
                       "externaldrive.badge.checkmark", "key.horizontal", "book.closed"] {
            try expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                       "Missing SF Symbol: \(symbol)")
        }
        let initial = try await run("status")
        try expect(initial.values["HAS_KEY"] == "0", "Isolated directory should start empty")
        _ = try await run("keygen")
        let status = try await run("status")
        try expect(status.values["HAS_KEY"] == "1" && status.values["HAS_PRIV"] == "1", "Key status")
        let source = tmp.appendingPathComponent("测试 ' $(touch owned) 空格.1pux")
        let payload = Data(("mock backup content\n" + String(repeating: "test", count: 2048)).utf8)
        try payload.write(to: source)
        let encrypted = try await run("encrypt", source)
        let cipher = URL(fileURLWithPath: encrypted.values["OK_PATH"] ?? "")
        try expect(cipher.path == source.path + ".age", "Output path must survive argument handling")
        try expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("owned").path), "No shell interpolation")
        let verification = try await run("verify", cipher)
        try expect(verification.values["VERIFY"] == "OK", "Verification")
        try expect(verification.values["SHA256"] == encrypted.values["OK_SHA256"], "Digest agreement")
        do {
            _ = try await run("encrypt", source)
            throw NSError(domain: "NativeTests", code: 1)
        } catch let error as BackendFailure {
            try expect(error.code == 4, "Must preserve backend exit code")
            try expect(error.localizedDescription.contains("没有覆盖"), "Friendly error mapping")
        }
        try FileManager.default.removeItem(at: source)
        _ = try await run("decrypt", cipher)
        let restored = try Data(contentsOf: source)
        try expect(restored == payload, "Byte-for-byte round trip")
        let selftest = try await run("selftest")
        try expect(selftest.values["SELFTEST"] == "OK", "Self-test protocol")

        let keyDirectory = URL(fileURLWithPath: support)
        let publicText = tmp.appendingPathComponent("public export.txt")
        let privateText = tmp.appendingPathComponent("private export.txt")
        try await KeyTransfer.export(from: keyDirectory, privateKey: false, to: publicText, resources: root)
        try await KeyTransfer.export(from: keyDirectory, privateKey: true, to: privateText, resources: root)
        let publicExport = try KeyTransfer.readText(publicText)
        let privateExport = try KeyTransfer.readText(privateText)
        try expect(!publicExport.contains("AGE-SECRET-KEY-"), "Public export must never contain a private key")
        let importedPublic = try await KeyTransfer.validate(publicExport, resources: root)
        let importedPrivate = try await KeyTransfer.validate("\u{FEFF}" + privateExport.replacingOccurrences(of: "\n", with: "\r\n"), resources: root)
        try expect(importedPublic.privateKey == nil && importedPrivate.privateKey != nil, "Recognize key type, BOM and CRLF")
        try expect(importedPrivate.publicKey == importedPublic.publicKey, "Private key derives original public key")
        let exportedPermissions = try FileManager.default.attributesOfItem(atPath: privateText.path)[.posixPermissions] as? NSNumber
        try expect(exportedPermissions?.intValue == 0o600, "Private TXT permissions")
        do {
            try await KeyTransfer.export(from: keyDirectory, privateKey: true, to: privateText, resources: root)
            throw NSError(domain: "NativeTests", code: 1)
        } catch let failure as BackendFailure { try expect(failure.code == 28, "TXT export refuses overwrite") }
        let textRestore = tmp.appendingPathComponent("restore from text")
        try await KeyTransfer.install(importedPublic, into: textRestore, resources: root)
        try expect(!FileManager.default.fileExists(atPath: textRestore.appendingPathComponent("private.key").path), "Public import never creates private key")
        try await KeyTransfer.install(importedPrivate, into: textRestore, resources: root)
        try await KeyTransfer.install(importedPrivate, into: textRestore, resources: root)
        _ = try await Backend.run("selftest", resources: root, support: textRestore.path)
        let another = tmp.appendingPathComponent("another key")
        _ = try await Backend.run("keygen", resources: root, support: another.path)
        let different = try await KeyTransfer.validate(KeyTransfer.readText(another.appendingPathComponent("private.key")), resources: root)
        let beforeImport = try Data(contentsOf: textRestore.appendingPathComponent("private.key"))
        do {
            try await KeyTransfer.install(different, into: textRestore, resources: root)
            throw NSError(domain: "NativeTests", code: 1)
        } catch let failure as BackendFailure { try expect(failure.code == 28, "Different key must not overwrite") }
        let afterImport = try Data(contentsOf: textRestore.appendingPathComponent("private.key"))
        try expect(beforeImport == afterImport, "Conflict preserves old private key")
        for invalid in ["", "{\\rtf1 test}", "AGE-SECRET-KEY-1INVALID", publicExport + publicExport,
                        privateExport + different.publicKey + "\n", "# comment only\n"] {
            do {
                _ = try await KeyTransfer.validate(invalid, resources: root)
                throw NSError(domain: "NativeTests", code: 1)
            } catch let failure as BackendFailure {
                try expect(failure.code == 28, "Invalid or conflicting text rejected")
                try expect(!failure.localizedDescription.contains("AGE-SECRET-KEY-1INVALID"), "Do not echo private text in diagnostics")
            }
        }
        let encryptedPrivate = privateExport.replacingOccurrences(of: "AGE-SECRET-KEY-1", with: "AGE-SECRET-KEY-2")
        do {
            _ = try await KeyTransfer.validate(encryptedPrivate, resources: root)
            throw NSError(domain: "NativeTests", code: 1)
        } catch is BackendFailure { }
        let linkedExport = tmp.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: linkedExport, withDestinationURL: privateText)
        do {
            _ = try KeyTransfer.readText(linkedExport)
            throw NSError(domain: "NativeTests", code: 1)
        } catch is BackendFailure { }
        let oversized = tmp.appendingPathComponent("too large.txt")
        try Data(repeating: 65, count: 65537).write(to: oversized)
        do {
            _ = try KeyTransfer.readText(oversized)
            throw NSError(domain: "NativeTests", code: 1)
        } catch is BackendFailure { }
        print("Key TXT: public/private export, private recovery, CRLF/BOM, pairing, idempotence, conflicts, invalid input, permissions: PASS")
        let relocated = tmp.appendingPathComponent("external keys")
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        try KeyLocation.copyKeys(from: keyDirectory, to: relocated)
        let originalPrivate = try Data(contentsOf: keyDirectory.appendingPathComponent("private.key"))
        let relocatedPrivate = try Data(contentsOf: relocated.appendingPathComponent("private.key"))
        try expect(originalPrivate == relocatedPrivate, "Key relocation must copy without changing the key")
        _ = try await Backend.run("checkkeys", resources: root, support: relocated.path)
        _ = try await Backend.run("selftest", resources: root, support: relocated.path)
        let settings = tmp.appendingPathComponent("preferences/settings.plist")
        try KeyLocation.save(relocated, settings: settings)
        let resolved = try KeyLocation.resolve(settings: settings, environment: [:])
        try expect(resolved.path == relocated.path, "Saved path must round-trip")
        do {
            try KeyLocation.copyKeys(from: keyDirectory, to: relocated)
            throw NSError(domain: "NativeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Must not overwrite keys"])
        } catch let error as NSError {
            try expect(error.domain != "NativeTests", "Existing key must prevent a second copy")
        }
        let afterAttempt = try Data(contentsOf: relocated.appendingPathComponent("private.key"))
        try expect(afterAttempt == originalPrivate, "Failed copy must preserve destination and source")
        let conflict = tmp.appendingPathComponent("conflict")
        try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true)
        let preexistingPublic = conflict.appendingPathComponent("public.key")
        try Data("keep existing file".utf8).write(to: preexistingPublic)
        do {
            try KeyLocation.copyKeys(from: keyDirectory, to: conflict)
            throw NSError(domain: "NativeTests", code: 1)
        } catch let error as NSError {
            try expect(error.domain != "NativeTests", "Conflicting public key must fail")
        }
        let keptPublic = try Data(contentsOf: preexistingPublic)
        try expect(keptPublic == Data("keep existing file".utf8), "Existing public key survives partial copy failure")
        try expect(!FileManager.default.fileExists(atPath: conflict.appendingPathComponent("private.key").path), "Only new copy is rolled back")
        let directoryLink = tmp.appendingPathComponent("linked destination")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: conflict)
        do {
            try KeyLocation.copyKeys(from: keyDirectory, to: directoryLink)
            throw NSError(domain: "NativeTests", code: 1)
        } catch let failure as BackendFailure {
            try expect(failure.code == 25, "Linked key directory rejected before copying")
        }
        let folder = tmp.appendingPathComponent("文件夹备份")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try payload.write(to: folder.appendingPathComponent("backup.1pux"))
        let folderReply = try await run("encrypt", folder)
        try expect(folderReply.values["OK_KIND"] == "folder", "Folder encryption result")
        try FileManager.default.removeItem(at: folder)
        let folderCipher = URL(fileURLWithPath: folderReply.values["OK_PATH"]!)
        let restoredFolder = try await Backend.run("decrypt", file: folderCipher, resources: root, support: relocated.path)
        try expect(restoredFolder.values["OK_KIND"] == "folder", "Copied keys must restore the encrypted folder")
        let restoredPayload = try Data(contentsOf: folder.appendingPathComponent("backup.1pux"))
        try expect(restoredPayload == payload, "Restored folder content must match")
        try FileManager.default.removeItem(at: relocated)
        do {
            _ = try KeyLocation.resolve(settings: settings, environment: [:])
            throw NSError(domain: "NativeTests", code: 1)
        } catch let failure as BackendFailure {
            try expect(failure.code == 25, "Missing configured volume must not fall back to default")
        }
        for mode in Operation.allCases {
            try expect(!mode.title.isEmpty && !mode.action.isEmpty && !mode.note.isEmpty, "All operation labels")
        }
        print("Native bridge: parsing, encryption, folder restore, key copy, persistence, no overwrite, missing-volume handling: PASS")
    }
}
