import UIKit

// Ключи обмена между расширением и приложением.
// Значения должны совпадать с ShareContract в ShareViewController.swift.
enum SharedPaths {
    static let appGroupID = "group.com.personal.iphoneplayer"
    static let inboxFolderName = "Inbox"
    static let pasteboardKey = "PLAYBOOK_INBOX_FILES"

    static var appGroupInboxURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        return container.appendingPathComponent(inboxFolderName, isDirectory: true)
    }
}

// Забирает файлы, переданные Share-расширением:
// из общей папки App Group (платная учётка)
// или из системного буфера обмена (бесплатная учётка).
enum SharedInbox {

    /// Возвращает URL файлов, сохранённых в стабильное место,
    /// и очищает источник передачи за собой.
    static func takeFiles() -> [URL] {
        var urls: [URL] = []
        urls.append(contentsOf: takeFromAppGroup())
        urls.append(contentsOf: takeFromPasteboard())
        return urls
    }

    // MARK: - Папка App Group

    private static func takeFromAppGroup() -> [URL] {
        guard let dir = SharedPaths.appGroupInboxURL else { return [] }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let storage = sessionStorageDirectory()
        var urls: [URL] = []

        for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                continue
            }

            let destination = uniqueURL(for: fileURL.lastPathComponent, in: storage)

            do {
                try fm.moveItem(at: fileURL, to: destination)
                urls.append(destination)
            } catch {
                // Если переместить не вышло — копируем содержимое
                if let data = try? Data(contentsOf: fileURL) {
                    do {
                        try data.write(to: destination)
                        try? fm.removeItem(at: fileURL)
                        urls.append(destination)
                    } catch {
                        // пропускаем нечитаемый файл
                    }
                }
            }
        }

        return urls
    }

    // MARK: - Буфер обмена

    private static func takeFromPasteboard() -> [URL] {
        let pasteboard = UIPasteboard.general
        guard let packed = pasteboard.data(forPasteboardType: SharedPaths.pasteboardKey) else {
            return []
        }

        guard let payload = try? JSONSerialization.jsonObject(with: packed) as? [String: Any],
              let entries = payload["files"] as? [[String: String]] else {
            return []
        }

        let storage = sessionStorageDirectory()
        var urls: [URL] = []

        for entry in entries {
            guard let name = entry["name"], let base64 = entry["data"],
                  let data = Data(base64Encoded: base64) else {
                continue
            }

            let destination = uniqueURL(for: name, in: storage)
            do {
                try data.write(to: destination)
                urls.append(destination)
            } catch {
                // пропускаем нечитаемый файл
            }
        }

        clearPasteboardEntry()

        return urls
    }

    private static func clearPasteboardEntry() {
        let pasteboard = UIPasteboard.general
        let items = pasteboard.items
        let filtered = items.filter { item in
            item[SharedPaths.pasteboardKey] == nil
        }
        if filtered.count != items.count {
            pasteboard.items = filtered
        }
    }

    // MARK: - Вспомогательное

    private static func sessionStorageDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(sanitize(name))
        var counter = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = candidate.pathExtension
            let base = candidate.deletingPathExtension().lastPathComponent
            let suffix = " (\(counter))"
            let newName = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }

        return candidate
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "файл" : cleaned
    }
}

