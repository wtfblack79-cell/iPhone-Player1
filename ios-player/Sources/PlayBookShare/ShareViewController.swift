import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    // MARK: - Константы (должны совпадать с SharedInbox.swift в основном приложении)

    private let appGroupID = "group.com.personal.iphoneplayer"
    private let inboxFolderName = "Inbox"

    private let supportedTypes: Set<String> = [
        "public.audio",
        "public.mp3",
        "public.mpeg-4-audio",
        "com.apple.m4a-audio",
        "com.apple.m4b-audio",
        "public.aac-audio",
        "com.microsoft.waveform-audio",
        "public.aiff-audio",
        "com.apple.coreaudio-format",
        "org.xiph.flac",
        "com.fictionbook.fb2",
        "org.idpf.epub-container",
        "public.plain-text",
        "public.xml"
    ]

    private let statusLabel = UILabel()
    private var pendingCount = 0
    private var savedCount = 0
    private var finished = false

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processAttachments()
    }

    private func setupUI() {
        view.backgroundColor = .systemBlue

        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Передача файлов…"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)
    }

    // MARK: - Обработка входящих файлов

    private func processAttachments() {
        guard let extensionContext else {
            fail("Не удалось получить контекст расширения")
            return
        }

        let items = (extensionContext.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }

        guard !attachments.isEmpty else {
            fail("Файлы не найдены")
            return
        }

        pendingCount = attachments.count

        // Страховка: если система не ответит ни на один запрос — закрываемся сами
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finishIfPending()
        }

        for attachment in attachments {
            let registered = attachment.registeredTypeIdentifiers

            // Сначала пробуем наш тип напрямую,
            // затем любой аудио-тип, затем общую файловую ссылку
            let chosen = registered.first { supportedTypes.contains($0) }
                ?? registered.first { UTType($0)?.conforms(to: .audio) ?? false }

            if let type = chosen {
                attachment.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let url {
                            self.saveFile(
                                from: url,
                                suggestedName: attachment.suggestedName,
                                typeIdentifier: type
                            )
                        }
                        self.attachmentDone()
                    }
                }
            } else if registered.contains("public.file-url") {
                attachment.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let url = Self.fileURL(from: item) {
                            self.saveFile(
                                from: url,
                                suggestedName: attachment.suggestedName,
                                typeIdentifier: nil
                            )
                        }
                        self.attachmentDone()
                    }
                }
            } else {
                attachmentDone()
            }
        }
    }

    // MARK: - Сохранение файла в общую папку

    private func inboxDirectory() -> URL? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        let inbox = base.appendingPathComponent(inboxFolderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return inbox
        } catch {
            return nil
        }
    }

    private func saveFile(from source: URL, suggestedName: String?, typeIdentifier: String?) {
        guard let inbox = inboxDirectory() else { return }

        var name = (suggestedName ?? source.lastPathComponent) as NSString
        name = name.lastPathComponent as NSString

        // Расширение: из исходного имени, иначе — из типа
        var ext = source.pathExtension.lowercased()
        if ext.isEmpty, let type = typeIdentifier,
           let preferred = UTType(type)?.preferredFilenameExtension {
            ext = preferred.lowercased()
        }

        let nameExt = (name.pathExtension as String).lowercased()
        let finalExt = nameExt.isEmpty ? ext : nameExt
        let baseName = finalExt.isEmpty
            ? (name as String)
            : (name.deletingPathExtension as String) + "." + finalExt

        // Уникальное имя внутри Inbox
        var dest = inbox.appendingPathComponent(baseName)
        var counter = 1
        let stem = (baseName as NSString).deletingPathExtension
        let destExt = (baseName as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = destExt.isEmpty
                ? inbox.appendingPathComponent("\(stem) (\(counter))")
                : inbox.appendingPathComponent("\(stem) (\(counter)).\(destExt)")
            counter += 1
        }

        do {
            // URL из loadFileRepresentation живёт только внутри колбэка —
            // копируем синхронно и сразу
            try FileManager.default.copyItem(at: source, to: dest)
            savedCount += 1
        } catch {
            // Файл не сохранён — финальное сообщение покажет результат
        }
    }

    private static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string) {
            return url
        }
        return nil
    }

    // MARK: - Завершение

    private func attachmentDone() {
        pendingCount -= 1
        if pendingCount <= 0 {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true

        if savedCount > 0 {
            statusLabel.text = "Файлов передано: \(savedCount)\nОткрываю PlayBook…"
            openHostApp()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.complete()
            }
        } else {
            fail("Не удалось скопировать файл")
        }
    }

    private func finishIfPending() {
        guard !finished else { return }

        if savedCount > 0 {
            finish()
        } else {
            // Запросы так и не отработали — закрываемся,
            // приложение заберёт файлы при следующем запуске
            complete()
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true

        statusLabel.text = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Открытие основного приложения

    private func openHostApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.perform(#selector(openURL(_:)), with: url)
                return
            }
            responder = current.next
        }
    }

    @objc private func openURL(_ url: URL) { }
}
