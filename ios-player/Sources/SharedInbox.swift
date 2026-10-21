import UIKit

// Приёмник файлов, переданных из Share Extension.
// Забирает файлы и из общей папки App Group, и из буфера обмена
// (канал для бесплатной учётки разработчика), чистит за собой.
//
// Ключи пометок совместимы с Sources/PlayBookShare/ShareViewController.swift

enum SharedInbox {

    private static let appGroupID = "group.com.personal.iphoneplayer"
    private static let inboxFolderName = "Inbox"
    private static let dataKey = "com.personal.iphoneplayer.shared-file.data"
    private static let nameKey = "com.personal.iphoneplayer.shared-file.name"
    private static let sessionKey = "com.personal.iphoneplayer.shared-file.session"
    private static let processedSessionsKey = "playbook.sharedInbox.processedSessions"

    // Забирает все переданные файлы и возвращает их локальные URL.
    static func takeFiles() -> [URL] {
        var urls: [URL] = []
        urls.append(contentsOf: takeFromAppGroup())
        urls.append(contentsOf: takeFromPasteboard())
        return urls
    }

    // MARK: - Папка для принятых файлов

    private static func importDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedInboxImport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Путь 1: общая папка App Group

    private static func takeFromAppGroup() -> [URL] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return []
        }

        let inbox = container.appendingPathComponent(inboxFolderName, isDirectory: true)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: inbox.path), !names.isEmpty else {
            return []
        }

        let destination = importDirectory()
        var urls: [URL] = []

        for name in names.sorted() {
            let source = inbox.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let target = uniqueTarget(in: destination, preferredName: name)
            if (try? fileManager.copyItem(at: source, to: target)) != nil {
                urls.append(target)
                try? fileManager.removeItem(at: source)
            }
        }

        return urls
    }

    // MARK: - Путь 2: буфер обмена (файлы с нашими пометками)

    private static func takeFromPasteboard() -> [URL] {
        let items = UIPasteboard.general.items
        guard !items.isEmpty else { return [] }

        var processed = Set(UserDefaults.standard.stringArray(forKey: processedSessionsKey) ?? [])

        var collected: [(session: String, name: String, data: Data)] = []
        for item in items {
            guard let data = item[dataKey] as? Data else { continue }
            let session = (item[sessionKey] as? String) ?? UUID().uuidString
            guard !processed.contains(session) else { continue }
            let name = (item[nameKey] as? String) ?? "file-\(UUID().uuidString.prefix(6)).bin"
            collected.append((session, name, data))
        }

        guard !collected.isEmpty else { return [] }

        let destination = importDirectory()
        var urls: [URL] = []

        for entry in collected {
            let target = uniqueTarget(in: destination, preferredName: entry.name)
            do {
                try entry.data.write(to: target)
                urls.append(target)
                processed.insert(entry.session)
            } catch {
                continue
            }
        }

        UserDefaults.standard.set(Array(processed), forKey: processedSessionsKey)
        return urls
    }

    // MARK: - Имена файлов

    private static func uniqueTarget(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let base = (preferredName as NSString).lastPathComponent
        var candidate = directory.appendingPathComponent(base)
        var counter = 1

        while fileManager.fileExists(atPath: candidate.path) {
            let nameNoExt = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            let newName = ext.isEmpty
                ? "\(nameNoExt) (\(counter))"
                : "\(nameNoExt) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }

        return candidate
    }
}
