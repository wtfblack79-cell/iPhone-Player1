import Foundation
import UIKit

// Приёмник файлов от Share Extension.
// Читает папку Inbox в App Group (платная учётка)
// или системный буфер обмена (бесплатная учётка).

enum SharedInbox {

    private static let appGroupId = "group.com.personal.iphoneplayer"
    private static let payloadPrefix = "PLAYBOOK1:"

    static func takeFiles() -> [URL] {
        var urls = takeFromInboxDirectory()

        if urls.isEmpty {
            urls = takeFromPasteboard()
        }

        return urls
    }

    private static func appDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    private static func inboxDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }

        let dir = container.appendingPathComponent("Inbox", isDirectory: true)
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dir
        }

        return nil
    }

    private static func takeFromInboxDirectory() -> [URL] {
        guard let dir = inboxDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !contents.isEmpty else {
            return []
        }

        let targetDirectory = appDocumentsDirectory()
        var urls: [URL] = []

        for fileURL in contents where !fileURL.hasDirectoryPath {
            let name = uniqueFileName(fileURL.lastPathComponent, in: targetDirectory)
            let destination = targetDirectory.appendingPathComponent(name)

            if (try? FileManager.default.copyItem(at: fileURL, to: destination)) != nil {
                urls.append(destination)
            }
        }

        if !urls.isEmpty {
            for fileURL in contents {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        return urls
    }

    private static func takeFromPasteboard() -> [URL] {
        guard let raw = UIPasteboard.general.string, raw.hasPrefix(payloadPrefix) else {
            return []
        }

        let base64 = String(raw.dropFirst(payloadPrefix.count))
        guard let json = Data(base64Encoded: base64),
              let array = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            // это наш мусор, но разобрать не смогли — чистим
            UIPasteboard.general.string = ""
            return []
        }

        let targetDirectory = appDocumentsDirectory()
        var urls: [URL] = []

        for record in array {
            guard let name = record["name"] as? String,
                  let data = record["data"] as? Data,
                  !data.isEmpty else {
                continue
            }

            let destination = targetDirectory.appendingPathComponent(uniqueFileName(name, in: targetDirectory))

            if (try? data.write(to: destination)) != nil {
                urls.append(destination)
            }
        }

        // забрали свои данные — чистим буфер
        UIPasteboard.general.string = ""

        return urls
    }

    private static func uniqueFileName(_ name: String, in directory: URL) -> String {
        var candidate = name
        var counter = 1

        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension

            if ext.isEmpty {
                candidate = "\(base) (\(counter))"
            } else {
                candidate = "\(base) (\(counter)).\(ext)"
            }

            counter += 1
        }

        return candidate
    }
}
