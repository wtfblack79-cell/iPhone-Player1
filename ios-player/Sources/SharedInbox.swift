import Foundation
import UniformTypeIdentifiers

// Забирает файлы, которые расширение PlayBookShare положило
// в общую папку app group.
// Книги — в EBookStore (Documents/EBooks), аудио — в корень Documents,
// который сканирует аудиобиблиотека.
enum SharedInbox {

    // Должно совпадать с Config в ShareViewController.swift
    private static let appGroupID = "group.com.personal.iphoneplayer"
    private static let inboxFolderName = "SharedInbox"

    private static let bookExtensions: Set<String> = ["fb2", "epub", "txt"]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf", "oga"
    ]

    static func inboxURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(inboxFolderName, isDirectory: true)
    }

    /// Переносит все файлы из общей папки расширения в библиотеки приложения.
    /// Возвращает количество импортированных файлов.
    @discardableResult
    @MainActor
    static func consume(ebookStore: EBookStore?) -> Int {
        guard let inbox = inboxURL() else { return 0 }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else {
            return 0
        }

        var imported = 0

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = file.pathExtension.lowercased()
            guard ext != "tmp" else { continue }

            if bookExtensions.contains(ext), let store = ebookStore, store.importBook(from: file) != nil {
                imported += 1
                try? fm.removeItem(at: file)
            } else if audioExtensions.contains(ext) {
                let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destination = uniqueDestination(for: file.lastPathComponent, in: documents)
                do {
                    try fm.moveItem(at: file, to: destination)
                    imported += 1
                } catch {
                    // Файл остаётся в папке и будет обработан при следующем запуске
                }
            }
        }

        return imported
    }

    private static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension

        var candidate = directory.appendingPathComponent(name)
        var counter = 1

        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
