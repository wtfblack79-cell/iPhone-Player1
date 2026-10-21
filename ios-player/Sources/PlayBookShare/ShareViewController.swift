import UIKit

// Ключи обмена между расширением и приложением.
// Значения должны совпадать с SharedPaths в SharedInbox.swift.
enum ShareContract {
    static let appGroupID = "group.com.personal.iphoneplayer"
    static let inboxFolderName = "Inbox"
    static let pasteboardKey = "PLAYBOOK_INBOX_FILES"
}

struct ExtractedFile {
    let name: String
    let data: Data
}

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private var isFinishing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startTransfer()
    }

    // MARK: - Экран

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = text
        }
    }

    // MARK: - Передача

    private func startTransfer() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .compactMap { $0.attachments }
            .flatMap { $0 }

        guard !providers.isEmpty else {
            finish(message: "Файлы не найдены")
            return
        }

        setStatus("Передача файлов (\(providers.count))...")

        let lock = NSLock()
        var collected: [ExtractedFile] = []
        let group = DispatchGroup()

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(message: "Не удалось прочитать файлы")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        for provider in providers {
            group.enter()
            extractFile(from: provider) { file in
                if let file = file {
                    lock.lock()
                    collected.append(file)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            timeout.cancel()
            guard let self = self, !self.isFinishing else { return }

            guard !collected.isEmpty else {
                self.finish(message: "Файлы не найдены")
                return
            }

            self.setStatus("Передача файлов...")

            let ok = self.deliver(collected)
            if ok {
                self.finish(message: "Файлов передано: \(collected.count)")
            } else {
                self.finish(message: "Не удалось скопировать файлы")
            }
        }
    }

    // Извлечение содержимого одного элемента шеринга.
    // Перебирает все реально зарегистрированные типы (включая dyn.),
    // для каждого пробует два способа чтения.
    private func extractFile(from provider: NSItemProvider, completion: @escaping (ExtractedFile?) -> Void) {

        let types = provider.registeredTypeIdentifiers

        guard !types.isEmpty else {
            completion(nil)
            return
        }

        var typeIndex = 0

        func finishWith(_ parsed: ExtractedFile?) {
            DispatchQueue.main.async {
                completion(parsed)
            }
        }

        func tryNextType() {
            guard typeIndex < types.count else {
                finishWith(nil)
                return
            }
            let type = types[typeIndex]
            typeIndex += 1

            // Шаг 1: прямое чтение содержимого
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                if let url = url, let data = try? Data(contentsOf: url) {
                    let name = self.suggestedOr(url.lastPathComponent, provider: provider)
                    finishWith(ExtractedFile(name: name, data: data))
                } else {
                    // Шаг 2: запасной универсальный способ
                    tryLoadItem(for: type)
                }
            }
        }

        func tryLoadItem(for type: String) {
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let parsed = self.parseLoadedItem(item, typeName: type, provider: provider) {
                    finishWith(parsed)
                } else {
                    tryNextType()
                }
            }
        }

        tryNextType()
    }

    private func parseLoadedItem(_ item: Any?, typeName: String, provider: NSItemProvider) -> ExtractedFile? {
        if let fileURL = item as? URL, fileURL.isFileURL, let data = try? Data(contentsOf: fileURL) {
            let name = suggestedOr(fileURL.lastPathComponent, provider: provider)
            return ExtractedFile(name: name, data: data)
        }

        if let nsURL = item as? NSURL, nsURL.isFileURL, let path = nsURL.path,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let name = suggestedOr(URL(fileURLWithPath: path).lastPathComponent, provider: provider)
            return ExtractedFile(name: name, data: data)
        }

        if let data = item as? Data {
            let ext = extensionGuess(from: typeName)
            let name = suggestedOr("файл." + ext, provider: provider)
            return ExtractedFile(name: name, data: data)
        }

        if let path = item as? String, path.hasPrefix("/"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let name = suggestedOr(URL(fileURLWithPath: path).lastPathComponent, provider: provider)
            return ExtractedFile(name: name, data: data)
        }

        return nil
    }

    private func suggestedOr(_ fallback: String, provider: NSItemProvider) -> String {
        if let suggested = provider.suggestedName, !suggested.isEmpty {
            return suggested
        }
        return fallback
    }

    private func extensionGuess(from typeName: String) -> String {
        if let dot = typeName.lastIndex(of: ".") {
            return String(typeName[typeName.index(after: dot)...])
        }
        return "bin"
    }

    // MARK: - Доставка файлов в приложение

    private func deliver(_ files: [ExtractedFile]) -> Bool {
        // Путь 1: общая папка App Group (работает на платной учётке)
        if deliverToAppGroup(files) {
            return true
        }

        // Путь 2: системный буфер обмена (работает на бесплатной учётке)
        return deliverToPasteboard(files)
    }

    private func deliverToAppGroup(_ files: [ExtractedFile]) -> Bool {
        guard let dir = appGroupInboxURL() else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        for file in files {
            let destination = uniqueURL(for: file.name, in: dir)
            do {
                try file.data.write(to: destination)
            } catch {
                return false
            }
        }
        return true
    }

    private func appGroupInboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareContract.appGroupID
        ) else {
            return nil
        }
        return container.appendingPathComponent(ShareContract.inboxFolderName, isDirectory: true)
    }

    private func deliverToPasteboard(_ files: [ExtractedFile]) -> Bool {
        var entries: [[String: String]] = []

        for file in files {
            entries.append([
                "name": file.name,
                "data": file.data.base64EncodedString()
            ])
        }

        let payload: [String: Any] = [
            "createdAt": Date().timeIntervalSince1970,
            "files": entries
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let packed = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        let pasteboard = UIPasteboard.general
        pasteboard.setItems(
            [[ShareContract.pasteboardKey: packed]],
            options: [.expirationDate: Date().addingTimeInterval(600)]
        )
        return true
    }

    private func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(sanitize(name))
        var counter = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = candidate.pathExtension
            let base = candidate.deletingPathExtension().lastPathComponent
            let suffix = " (\(counter))"
            let newName = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }

        return candidate
    }

    private func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "файл" : cleaned
    }

    // MARK: - Завершение

    private func finish(message: String) {
        guard !isFinishing else { return }
        isFinishing = true

        setStatus(message)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            self.openMainApp()
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func openMainApp() {
        let url = URL(string: "playbook://shared-inbox")!

        // Прямой open() из share-расширений запрещён,
        // используется общепринятый обходной путь через цепочку responders.
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")

        while let current = responder {
            if current.responds(to: selector), current !== self.view {
                current.perform(selector, with: url)
                break
            }
            responder = current.next
        }
    }
}

