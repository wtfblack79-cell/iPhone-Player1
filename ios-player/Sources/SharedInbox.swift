import Foundation

enum SharedInbox {
    static let appGroupId = "group.com.personal.iphoneplayer"

    static func hasPendingFiles() -> Bool {
        !inboxURLs().isEmpty
    }

    // Забирает файлы, оставленные share-расширением, и перемещает их
    // во временную папку приложения. Возвращает URL этих файлов.
    // Файлы убираются из Inbox, чтобы при следующем запуске не дублировались.
    static func takeFiles() -> [URL] {
        let urls = inboxURLs()
        guard !urls.isEmpty else { return [] }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInbox", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )

        var result: [URL] = []

        for url in urls {
            let destination = staging.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)

            do {
                try FileManager.default.moveItem(at: url, to: destination)
                result.append(destination)
            } catch {
                // файл с таким именем уже в staging — пропускаем дубликат
            }
        }

        return result
    }

    private static func inboxURLs() -> [URL] {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId
            )
        else {
            return []
        }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)

        return (try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        )) ?? []
    }
}
