import UIKit

// MARK: - Ошибки извлечения файлов

enum ExtractError: Error {
    case noAttachments
    case noSupportedType
    case noData
    case saveFailed
}

// MARK: - Извлечённый файл

struct ExtractedFile {
    let data: Data
    let suggestedName: String
}

// MARK: - Share Extension: приём файлов из системной шторки «Поделиться»

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let appGroupID = "group.com.personal.iphoneplayer"
    private let inboxFolderName = "Inbox"
    private var isFinished = false

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()

        // Страховка: через 12 секунд расширение закроется в любом случае,
        // чтобы шторка не повисла, если система не ответит на запрос файла
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.complete()
        }

        processIncomingItems()
    }

    // MARK: Интерфейс

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1)

        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 19)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Передача файлов..."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = text
        }
    }

    // MARK: Обработка входящих файлов

    private func processIncomingItems() {
        guard
            let items = extensionContext?.inputItems as? [NSExtensionItem],
            !items.isEmpty
        else {
            finishWithError("Файлы не найдены")
            return
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finishWithError("Файлы не найдены")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var extracted: [ExtractedFile] = []
        var hadReadError = false

        for provider in providers {
            group.enter()
            extractFile(from: provider) { result in
                defer { group.leave() }

                lock.lock()
                switch result {
                case .success(let file):
                    extracted.append(file)
                case .failure:
                    hadReadError = true
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            if extracted.isEmpty {
                self.finishWithError(
                    hadReadError ? "Не удалось скопировать файлы" : "Файлы не найдены"
                )
                return
            }

            self.save(extracted)
        }
    }

    // Перебираем ВСЕ реально зарегистрированные типы файла (включая динамические dyn.),
    // пока какой-нибудь не вернёт содержимое. Не угадываем тип заранее —
    // именно это было причиной «Файлы не найдены» в прошлой версии.

    private func extractFile(
        from provider: NSItemProvider,
        completion: @escaping (Result<ExtractedFile, ExtractError>) -> Void
    ) {
        let registered = provider.registeredTypeIdentifiers

        // Известные UTI — в приоритете, динамические dyn.… — в конец очереди
        let sorted = registered.sorted { a, b in
            let aDynamic = a.hasPrefix("dyn.")
            let bDynamic = b.hasPrefix("dyn.")
            if aDynamic != bDynamic { return !aDynamic }
            return a < b
        }

        tryLoadFileRepresentation(types: sorted, provider: provider, index: 0, completion: completion)
    }

    // Способ 1: loadFileRepresentation — штатный путь получения содержимого файла

    private func tryLoadFileRepresentation(
        types: [String],
        provider: NSItemProvider,
        index: Int,
        completion: @escaping (Result<ExtractedFile, ExtractError>) -> Void
    ) {
        guard index < types.count else {
            tryLoadItem(types: types, provider: provider, index: 0, completion: completion)
            return
        }

        let type = types[index]
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
            if let url = url, let data = try? Data(contentsOf: url) {
                DispatchQueue.main.async {
                    completion(.success(ExtractedFile(data: data, suggestedName: url.lastPathComponent)))
                }
                return
            }

            DispatchQueue.main.async {
                self?.tryLoadFileRepresentation(types: types, provider: provider, index: index + 1, completion: completion)
            }
        }
    }

    // Способ 2 (запасной): loadItem — URL, данные или строка-ссылка

    private func tryLoadItem(
        types: [String],
        provider: NSItemProvider,
        index: Int,
        completion: @escaping (Result<ExtractedFile, ExtractError>) -> Void
    ) {
        guard index < types.count else {
            completion(.failure(.noData))
            return
        }

        let type = types[index]
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in

            if let url = item as? URL, let data = try? Data(contentsOf: url) {
                DispatchQueue.main.async {
                    completion(.success(ExtractedFile(data: data, suggestedName: url.lastPathComponent)))
                }
                return
            }

            if let data = item as? Data {
                DispatchQueue.main.async {
                    completion(.success(ExtractedFile(data: data, suggestedName: "shared_file")))
                }
                return
            }

            if let link = item as? String, let url = URL(string: link), let data = try? Data(contentsOf: url) {
                DispatchQueue.main.async {
                    completion(.success(ExtractedFile(data: data, suggestedName: url.lastPathComponent)))
                }
                return
            }

            DispatchQueue.main.async {
                self?.tryLoadItem(types: types, provider: provider, index: index + 1, completion: completion)
            }
        }
    }

    // MARK: Сохранение в общую папку

    private func save(_ files: [ExtractedFile]) {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            finishWithError("Нет доступа к общей папке (App Group)")
            return
        }

        let inbox = groupURL.appendingPathComponent(inboxFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            finishWithError("Не удалось создать папку приёма")
            return
        }

        var savedCount = 0
        for file in files {
            let name = uniqueFileName(for: file.suggestedName, in: inbox)
            let destination = inbox.appendingPathComponent(name)
            do {
                try file.data.write(to: destination)
                savedCount += 1
            } catch {
                // Файл, который не удалось записать, пропускаем
            }
        }

        if savedCount == 0 {
            finishWithError("Не удалось скопировать файлы")
            return
        }

        setStatus("Файлов передано: \(savedCount)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.openHostApp()
        }
    }

    private func uniqueFileName(for originalName: String, in directory: URL) -> String {
        var base = originalName
        if base.isEmpty { base = "shared_file" }
        if (base as NSString).pathExtension.isEmpty { base += ".dat" }

        var candidate = base
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let nameNoExt = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            candidate = "\(nameNoExt) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    // MARK: Открытие основного приложения

    private func openHostApp() {
        // Прямой UIApplication.open из share-расширения запрещён системой,
        // поэтому открываем приложение через цепочку responders
        let url = URL(string: "playbook://shared-inbox")
        let selector = NSSelectorFromString("openURL:")

        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url as Any)
                break
            }
            responder = current.next
        }

        complete()
    }

    // MARK: Завершение

    private func complete() {
        guard !isFinished else { return }
        isFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func finishWithError(_ message: String) {
        setStatus(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.complete()
        }
    }
}
