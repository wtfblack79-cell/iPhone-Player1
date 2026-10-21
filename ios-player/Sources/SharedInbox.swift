import Foundation

// Забирает файлы, положенные Share-расширением в общую папку App Group,
// и раскладывает их по хранилищам приложения: книги — в EBookStore (Documents/EBooks),
// аудио — в корень Documents, где их подхватывает аудиобиблиотека.

enum SharedInbox {
    private static let appGroupID = "group.com.personal.iphoneplayer"
    private static let inboxFolderName = "Inbox"
    private static let bookExtensions: Set<String> = ["fb2", "epub", "txt"]

    @MainActor
    static func consume(ebookStore: EBookStore) {
        let fileManager = FileManager.default

        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }

        let inbox = container.appendingPathComponent(inboxFolderName, isDirectory: true)

        guard let files = try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        for file in files where file.lastPathComponent != ".DS_Store" {
            let ext = file.pathExtension.lowercased()

            if bookExtensions.contains(ext) {
                // Книга: штатный импорт приложения (копирует в Documents/EBooks и парсит название)
                _ = ebookStore.importBook(from: file)
                try? fileManager.removeItem(at: file)
            } else {
                // Аудио: кладём в корень Documents, где его сканирует аудиобиблиотека
                let destination = documents.appendingPathComponent(file.lastPathComponent)

                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: file)
                } else {
                    try? fileManager.moveItem(at: file, to: destination)
                }
            }
        }
    }
}
