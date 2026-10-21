import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private struct PendingFile {
        let name: String
        let data: Data
    }

    private let statusLabel = UILabel()
    private let appGroupID = "group.com.personal.iphoneplayer"
    private let inboxFolderName = "Inbox"
    private let maxClipboardFileBytes = 30 * 1024 * 1024

    private var pendingFiles: [PendingFile] = []
    private let filesLock = NSLock()
    private var isFinishing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        extractAllFiles()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .systemBlue

        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Передача файлов…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    // MARK: - Извлечение файлов

    private func extractAllFiles() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finishWithError("Файлы не найдены")
            return
        }

        var providers: [NSItemProvider] = []
        for item in items {
            providers.append(contentsOf: item.attachments ?? [])
        }

        guard !providers.isEmpty else {
            finishWithError("Файлы не найдены")
            return
        }

        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            extractFile(from: provider) { [weak self] file in
                if let file = file, let self = self {
                    self.filesLock.lock()
                    self.pendingFiles.append(file)
                    self.filesLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.deliverFiles()
        }

        // Страховка: если система не ответит — закрываемся сами
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, !self.isFinishing else { return }
            self.statusLabel.text = "Не удалось передать файлы"
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func extractFile(from provider: NSItemProvider, completion: @escaping (PendingFile?) -> Void) {
        var finished = false
        let types = provider.registeredTypeIdentifiers

        func finishOnce(_ file: PendingFile?) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(file)
            }
        }

        // Запасной путь: loadItem по первому доступному типу
        func tryLoadItem() {
            let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
                ?? UTType.data.identifier

            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                DispatchQueue.main.async {
                    var file: PendingFile?

                    switch item {
                    case let url as URL:
                        if let data = try? Data(contentsOf: url) {
                            let name = Self.resolvedName(from: url,
                                                         suggested: provider.suggestedName,
                                                         typeIdentifier: type)
                            file = PendingFile(name: name, data: data)
                        }
                    case let data as Data:
                        let name = Self.resolvedName(from: nil,
                                                     suggested: provider.suggestedName,
                                                     typeIdentifier: type)
                        file = PendingFile(name: name, data: data)
                    case let string as String:
                        let url = URL(string: string) ?? URL(fileURLWithPath: string)
                        if let data = try? Data(contentsOf: url) {
                            let name = Self.resolvedName(from: url,
                                                         suggested: provider.suggestedName,
                                                         typeIdentifier: type)
                            file = PendingFile(name: name, data: data)
                        }
                    default:
                        break
                    }

                    finishOnce(file)
                }
            }
        }

        // Основной путь: loadFileRepresentation по каждому реально
        // зарегистрированному типу (включая динамические dyn.…)
        func tryType(_ index: Int) {
            guard index < types.count else {
                tryLoadItem()
                return
            }
            let type = types[index]
            guard provider.hasItemConformingToTypeIdentifier(type) else {
                tryType(index + 1)
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _, _ in
                DispatchQueue.main.async {
                    if let url = url, let data = try? Data(contentsOf: url) {
                        let name = Self.resolvedName(from: url,
                                                     suggested: provider.suggestedName,
                                                     typeIdentifier: type)
                        finishOnce(PendingFile(name: name, data: data))
                    } else {
                        tryType(index + 1)
                    }
                }
            }
        }

        tryType(0)
    }

    private static func resolvedName(from url: URL?, suggested: String?, typeIdentifier: String) -> String {
        if let url = url, !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }

        var base = suggested ?? "file-\(UUID().uuidString.prefix(6))"
        if (base as NSString).pathExtension.isEmpty {
            let ext = UTType(typeIdentifier)?.preferredFilenameExtension
            if let ext = ext {
                base += ".\(ext)"
            }
        }
        return base
    }

    // MARK: - Доставка

    private func deliverFiles() {
        guard !isFinishing else { return }
        isFinishing = true

        filesLock.lock()
        let files = pendingFiles
        filesLock.unlock()

        guard !files.isEmpty else {
            finishWithError("Файлы не найдены")
            return
        }

        // Путь 1: общая папка App Group (работает на платной учётке)
        if saveToAppGroup(files) {
            finishWithSuccess(count: files.count)
            return
        }

        // Путь 2: буфер обмена (работает на бесплатной учётке)
        let oversized = files.contains { $0.data.count > maxClipboardFileBytes }
        if !oversized && writeToPasteboard(files) {
            finishWithSuccess(count: files.count)
            return
        }

        finishWithError(oversized
            ? "Файл слишком большой — используйте «Копировать в PlayBook»"
            : "Не удалось сохранить файлы")
    }

    private func saveToAppGroup(_ files: [PendingFile]) -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return false
        }

        let inbox = container.appendingPathComponent(inboxFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            for file in files {
                let destination = uniqueDestination(in: inbox, preferredName: file.name)
                try file.data.write(to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private func writeToPasteboard(_ files: [PendingFile]) -> Bool {
        let sessionID = UUID().uuidString
        var items = UIPasteboard.general.items

        for file in files {
            var item: [String: Any] = [:]
            item[Self.dataKey] = file.data
            item[Self.nameKey] = file.name
            item[Self.sessionKey] = sessionID
            items.append(item)
        }

        UIPasteboard.general.items = items
        return true
    }

    // MARK: - Ключи совместимы с SharedInbox (Sources/SharedInbox.swift)

    private static let dataKey = "com.personal.iphoneplayer.shared-file.data"
    private static let nameKey = "com.personal.iphoneplayer.shared-file.name"
    private static let sessionKey = "com.personal.iphoneplayer.shared-file.session"

    // MARK: - Открытие приложения (обходной путь: прямой open() из расширений запрещён)

    private func openApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    // MARK: - Завершение

    private func finishWithSuccess(count: Int) {
        statusLabel.text = "Файлов передано: \(count)"
        openApp()
        completeRequest(after: 1.2)
    }

    private func finishWithError(_ message: String) {
        statusLabel.text = message
        completeRequest(after: 2.5)
    }

    private func completeRequest(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    // MARK: - Имена файлов

    private func uniqueDestination(in directory: URL, preferredName: String) -> URL {
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
