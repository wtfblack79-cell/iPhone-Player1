import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    // MARK: - Настройки (должны совпадать с SharedInbox.swift в приложении)

    private enum Config {
        static let appGroupID = "group.com.personal.iphoneplayer"
        static let inboxFolderName = "SharedInbox"
    }

    // Типы, которые расширение принимает и кладёт в общую папку.
    // Список аудио повторяет NSExtensionActivationRule из project.yml.
    private let audioTypes: Set<String> = [
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

    private let bookTypes: Set<String> = [
        "com.fictionbook.fb2",
        "org.idpf.epub-container",
        "public.plain-text",
        "public.xml"
    ]

    private let statusLabel = UILabel()
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        importAttachments()
    }

    // MARK: - Интерфейс

    private func setupUI() {
        view.backgroundColor = .systemBlue
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Импорт в PlayBook…"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)
    }

    // MARK: - Импорт вложений

    private func importAttachments() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard !attachments.isEmpty else {
            finish()
            return
        }

        let group = DispatchGroup()
        let counter = Counter()

        for attachment in attachments {
            guard let typeIdentifier = acceptedTypeIdentifier(of: attachment) else { continue }

            group.enter()
            attachment.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] tempURL, _ in
                defer { group.leave() }

                guard let self, let tempURL else { return }
                if self.saveToInbox(tempURL: tempURL, attachment: attachment, typeIdentifier: typeIdentifier) {
                    counter.increment()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            if counter.value > 0 {
                self.statusLabel.text = "Файлы переданы в PlayBook"
                self.openMainApp()
            } else {
                self.statusLabel.text = "Не удалось скопировать файл"
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.finish()
            }
        }
    }

    // MARK: Выбор типа вложения

    private func acceptedTypeIdentifier(of attachment: NSItemProvider) -> String? {
        let identifiers = attachment.registeredTypeIdentifiers

        for identifier in identifiers where audioTypes.contains(identifier) {
            return identifier
        }
        for identifier in identifiers where bookTypes.contains(identifier) && identifier != "public.xml" {
            return identifier
        }
        // Страховка: файл .fb2 мог быть определён системой как обычный XML
        if identifiers.contains("public.xml") {
            return "public.xml"
        }
        return nil
    }

    // MARK: Копирование в общую папку

    private func saveToInbox(tempURL: URL, attachment: NSItemProvider, typeIdentifier: String) -> Bool {
        let fm = FileManager.default

        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupID) else {
            return false
        }

        let inbox = container.appendingPathComponent(Config.inboxFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            return false
        }

        var ext = tempURL.pathExtension.lowercased()
        if ext.isEmpty {
            ext = fileExtension(for: typeIdentifier)
        }

        let suggestedBase = (attachment.suggestedName as NSString?)?.deletingPathExtension ?? "файл"
        let name = "\(sanitize(suggestedBase))-\(UUID().uuidString.prefix(6)).\(ext)"
        let destination = inbox.appendingPathComponent(name)

        do {
            try fm.copyItem(at: tempURL, to: destination)
            return true
        } catch {
            return false
        }
    }

    private func fileExtension(for typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "com.fictionbook.fb2": return "fb2"
        case "org.idpf.epub-container": return "epub"
        case "public.plain-text": return "txt"
        case "public.mp3": return "mp3"
        case "com.apple.m4a-audio": return "m4a"
        case "com.apple.m4b-audio": return "m4b"
        case "org.xiph.flac": return "flac"
        case "com.microsoft.waveform-audio": return "wav"
        case "public.aiff-audio": return "aiff"
        case "com.apple.coreaudio-format": return "caf"
        default:
            if let ext = UTType(typeIdentifier)?.preferredFilenameExtension {
                return ext
            }
            return "dat"
        }
    }

    private func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "файл" : String(trimmed.prefix(64))
    }

    // MARK: - Открытие основного приложения

    // Стандартный обходной путь для share-расширений: искать объект
    // UIApplication по цепочке responders и вызвать openURL:,
    // потому что прямой вызов open() из расширения запрещён.
    private func openMainApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector), let application = current as? UIApplication {
                application.perform(selector, with: url as NSURL)
                return
            }
            responder = current.next
        }
    }

    // MARK: - Завершение

    private func finish() {
        guard !finished else { return }
        finished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - Потокобезопасный счётчик

private final class Counter {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
