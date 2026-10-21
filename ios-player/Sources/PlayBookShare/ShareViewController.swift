import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let appGroupID = "group.com.personal.iphoneplayer"
    private let inboxFolderName = "Inbox"

    private var totalItems = 0
    private var processedItems = 0
    private var savedCount = 0
    private var failedCount = 0
    private var finished = false

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1.0)

        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Передача файлов…"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)

        // Страховка: как бы всё ни пошло, шторка закроется сама не позже 12 секунд
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.finish()
        }

        processInput()
    }

    // MARK: - Обработка входящих файлов

    private func processInput() {
        guard let context = extensionContext,
              let items = context.inputItems as? [NSExtensionItem] else {
            fail("Не удалось получить данные из шторки")
            return
        }

        let attachments = items.flatMap { $0.attachments ?? [] }
        guard !attachments.isEmpty else {
            fail("Файлы не найдены")
            return
        }

        totalItems = attachments.count

        for attachment in attachments {
            loadAttachment(attachment)
        }
    }

    // Выбираем тип, который провайдер РЕАЛЬНО умеет отдать.
    // Это и была причина зависания: нельзя запрашивать файл по типу,
    // которого нет в registeredTypeIdentifiers — тогда колбэк не придёт никогда.
    private func preferredTypeIdentifier(for attachment: NSItemProvider) -> String {
        let registered = attachment.registeredTypeIdentifiers

        // Приоритет: файловые типы и наши книжные, затем аудио
        let fileLike = [
            "public.file-url",
            "com.fictionbook.fb2",
            "org.idpf.epub-container",
            "public.plain-text",
            "public.audio",
            "public.mp3",
            "public.mpeg-4-audio",
            "com.apple.m4a-audio",
            "com.apple.m4b-audio",
            "public.aac-audio",
            "com.microsoft.waveform-audio",
            "public.aiff-audio",
            "com.apple.coreaudio-format",
            "org.xiph.flac"
        ]

        if let hit = registered.first(where: { fileLike.contains($0) }) {
            return hit
        }
        if let data = registered.first(where: { $0 == UTType.data.identifier || $0 == UTType.item.identifier }) {
            return data
        }
        return registered.first ?? UTType.data.identifier
    }

    private func loadAttachment(_ attachment: NSItemProvider) {
        let typeID = preferredTypeIdentifier(for: attachment)

        // Основной путь: файловая ссылка (так отдаёт приложение «Файлы»)
        attachment.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
            DispatchQueue.main.async {
                if let url = url {
                    self?.copyFile(from: url)
                } else {
                    self?.loadAsItem(attachment)
                }
            }
        }
    }

    // Запасной путь: если файловая ссылка не сработала — пробуем URL или данные напрямую
    private func loadAsItem(_ attachment: NSItemProvider) {
        let registered = attachment.registeredTypeIdentifiers
        let identifier = registered.first(where: { $0 == "public.file-url" })
            ?? registered.first
            ?? UTType.data.identifier

        attachment.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                if let url = Self.url(from: item) {
                    self?.copyFile(from: url)
                } else if let data = item as? Data {
                    self?.copyData(data, suggestedName: "file")
                } else {
                    self?.itemFailed()
                }
            }
        }
    }

    private static func url(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let nsurl = item as? NSURL {
            return nsurl as URL
        }
        return nil
    }

    // MARK: - Сохранение в общую папку

    private func copyFile(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()

        let name = sanitizedFileName(from: sourceURL.lastPathComponent)
        saveDataOrMove(sourceURL: sourceURL, name: name)

        if accessed {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    private func saveDataOrMove(sourceURL: URL, name: String) {
        guard let inbox = inboxURL() else {
            fail("Общая папка недоступна — проверьте App Group")
            return
        }

        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = uniqueDestination(in: inbox, name: name)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destination)
            savedCount += 1
            itemProcessed()
        } catch {
            failedCount += 1
            itemProcessed()
        }
    }

    private func copyData(_ data: Data, suggestedName: String) {
        guard let inbox = inboxURL() else {
            fail("Общая папка недоступна — проверьте App Group")
            return
        }

        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = uniqueDestination(in: inbox, name: suggestedName)
            try data.write(to: destination)
            savedCount += 1
            itemProcessed()
        } catch {
            failedCount += 1
            itemProcessed()
        }
    }

    private func inboxURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(inboxFolderName, isDirectory: true)
    }

    private func sanitizedFileName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "file_" + UUID().uuidString.prefix(8)
        }
        return trimmed
    }

    private func uniqueDestination(in inbox: URL, name: String) -> URL {
        var destination = inbox.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let suffixed = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            destination = inbox.appendingPathComponent(suffixed)
            counter += 1
        }
        return destination
    }

    // MARK: - Завершение

    private func itemProcessed() {
        processedItems += 1
        if processedItems >= totalItems {
            finish()
        }
    }

    private func itemFailed() {
        failedCount += 1
        itemProcessed()
    }

    private func fail(_ message: String) {
        statusLabel.text = message
        finish(afterDelay: 1.5)
    }

    private func finish(afterDelay: TimeInterval = 0.8) {
        guard !finished else { return }
        finished = true

        if savedCount > 0 {
            statusLabel.text = "Файлов передано: \(savedCount)"
        } else if failedCount > 0 {
            statusLabel.text = "Не удалось скопировать файл"
        } else {
            statusLabel.text = "Файлы не найдены"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + afterDelay) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        if savedCount > 0 {
            openHostApp()
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func openHostApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }
}
