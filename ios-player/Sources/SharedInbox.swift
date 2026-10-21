import Foundation

// MARK: - Приём файлов, переданных через Share Extension
// Расширение складывает файлы в папку Inbox внутри app group.
// Этот модуль забирает их оттуда при запуске приложения или по URL-схеме.

enum SharedInbox {

    // Должно совпадать с ShareViewController.swift в расширении
    private static let appGroupID = "group.com.personal.iphoneplayer"
    private static let inboxFolderName = "Inbox"

    private static let bookExtensions: Set<String> = ["fb2", "epub", "txt"]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf"
    ]

    // MARK: Публичный API

    /// Забирает файлы из Inbox и маршрутизирует их:
    /// книги — в EBookStore, аудио — в корень Documents (там его сканирует аудиобиблиотека).
    /// Логика аудиобиблиотеки при этом не затрагивается.
    @MainActor
    static func consume(ebookStore: EBookStore) {
        let fileManager = FileManager.default

        guard let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let inbox = base.appendingPathComponent(inboxFolderName, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else {
            return
        }

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        for file in files where !file.hasDirectoryPath {
            let ext = file.pathExtension.lowercased()

            do {
                if bookExtensions.contains(ext) {
                    // Книга уходит в штатный импорт EBookStore —
                    // файл копируется в Documents/EBooks и появляется в библиотеке
                    _ = ebookStore.importBook(from: file)
                    try? fileManager.removeItem(at: file)
                } else if audioExtensions.contains(ext) {
                    let dest = uniqueURL(in: documents, suggestedName: file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: dest)
                } else {
                    // Неизвестный тип — удаляем, чтобы Inbox не засорялся
                    try? fileManager.removeItem(at: file)
                }
            } catch {
                // Файл останется в Inbox и будет обработан при следующем запуске
            }
        }
    }

    // MARK: Вспомогательное

    private static func uniqueURL(in directory: URL, suggestedName: String) -> URL {
        let fileManager = FileManager.default
        let name = (suggestedName as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var dest = directory.appendingPathComponent(name)
        var counter = 1

        while fileManager.fileExists(atPath: dest.path) {
            dest = ext.isEmpty
                ? directory.appendingPathComponent("\(stem) (\(counter))")
                : directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }

        return dest
    }
}
