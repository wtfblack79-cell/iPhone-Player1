import UIKit
import UniformTypeIdentifiers

// Приёмник файлов, переданных через Share-расширение.
// Согласован с ShareViewController: та же папка Inbox в App Group
// и тот же ключ в буфере обмена.

enum SharedInbox {

    private static let appGroupID = "group.com.personal.iphoneplayer"
    private static let pasteboardKey = "com.personal.iphoneplayer.shared-files"

    /// Забирает переданные файлы и возвращает их URL (копии в tmp приложения).
    /// Вызывать из .onAppear или .onOpenURL — файлы забираются один раз.
    static func takeFiles() -> [URL] {
        var files = takeFromAppGroup()
        if files.isEmpty {
            files = takeFromPasteboard()
        }
        return files
    }

    // MARK: - Путь 1: общая папка App Group (платная учётка)

    private static func takeFromAppGroup() -> [URL] {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return []
        }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else {
            return []
        }

        let files = contents.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        guard !files.isEmpty else { return [] }

        var result: [URL] = []
        for file in files {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(file.pathExtension)
            if (try? FileManager.default.copyItem(at: file, to: destination)) != nil {
                result.append(destination)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return result
    }

    // MARK: - Путь 2: буфер обмена (бесплатная учётка)

    private static func takeFromPasteboard() -> [URL] {
        let pasteboard = UIPasteboard.general
        guard let packed = pasteboard.data(forPasteboardType: pasteboardKey) else {
            return []
        }

        guard let payload = try? PropertyListSerialization
            .propertyList(from: packed, options: [], format: nil) as? [[String: Any]] else {
            return []
        }

        var result: [URL] = []
        for entry in payload {
            guard let name = entry["name"] as? String,
                  let data = entry["data"] as? Data else { continue }

            let safeName = sanitizedName(name)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + safeName)
            if (try? data.write(to: destination)) != nil {
                result.append(destination)
            }
        }

        // Очищаем наш след, чтобы не забрать файлы повторно
        pasteboard.items = []

        return result
    }

    private static func sanitizedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "_")
        return cleaned.isEmpty ? "файл" : cleaned
    }
}
