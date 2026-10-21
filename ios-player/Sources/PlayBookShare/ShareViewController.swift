import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let appGroupId = "group.com.personal.iphoneplayer"

    private var pendingAttachments: [NSItemProvider] = []
    private var importedCount = 0
    private var failureReasons: [String] = []
    private var isFinishing = false

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()

        // Страховка: шторка обязана закрыться, даже если что-то зависнет
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.finish()
        }

        collectAttachments()
    }

    // MARK: - Интерфейс

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

    // MARK: - Сбор входящих файлов

    private func collectAttachments() {
        guard
            let extensionContext = extensionContext,
            let items = extensionContext.inputItems as? [NSExtensionItem]
        else {
            fail("Файлы не найдены")
            return
        }

        let attachments = items.flatMap { $0.attachments ?? [] }

        guard !attachments.isEmpty else {
            fail("Файлы не найдены")
            return
        }

        pendingAttachments = attachments
        processNextAttachment()
    }

    private func processNextAttachment() {
        guard !pendingAttachments.isEmpty else {
            reportResult()
            return
        }

        let provider = pendingAttachments.removeFirst()

        extractFile(from: provider) { [weak self] result in
            guard let self = self else { return }

            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    if self.saveToInbox(data: payload.data, fileName: payload.fileName) {
                        self.importedCount += 1
                    } else {
                        self.failureReasons.append("Не удалось сохранить файл")
                    }
                case .failure(let message):
                    self.failureReasons.append(message)
                }
                self.processNextAttachment()
            }
        }
    }

    // MARK: - Извлечение содержимого

    private struct ExtractedFile {
        let data: Data
        let fileName: String
    }

    private func extractFile(
        from provider: NSItemProvider,
        completion: @escaping (Result<ExtractedFile, String>) -> Void
    ) {
        let identifiers = provider.registeredTypeIdentifiers
        let fallbackName = provider.suggestedName ?? "shared_file"

        // Путь 1: loadFileRepresentation по каждому из РЕАЛЬНО зарегистрированных
        // типов — не по заранее прописанному списку. Так файлы достаются даже
        // тогда, когда FB2 приходят под динамическим типом вида "dyn.…"
        func tryRepresentation(at index: Int) {
            guard index < identifiers.count else {
                tryLoadItem(at: 0)
                return
            }

            let typeIdentifier = identifiers[index]

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                if let url {
                    do {
                        let data = try Data(contentsOf: url)
                        if !data.isEmpty {
                            completion(.success(ExtractedFile(
                                data: data,
                                fileName: self.resolvedFileName(
                                    provider: provider,
                                    sourceURL: url,
                                    fallbackName: fallbackName
                                )
                            )))
                            return
                        }
                    } catch {
                        // читаемый файл не получился — пробуем следующий тип
                    }
                }
                tryRepresentation(at: index + 1)
            }
        }

        // Путь 2: loadItem — приходит URL или сырые данные
        func tryLoadItem(at index: Int) {
            guard index < identifiers.count else {
                completion(.failure("Не удалось прочитать файл"))
                return
            }

            provider.loadItem(forTypeIdentifier: identifiers[index], options: nil) { item, _ in
                if let url = item as? URL,
                   let data = try? Data(contentsOf: url),
                   !data.isEmpty {
                    completion(.success(ExtractedFile(
                        data: data,
                        fileName: url.lastPathComponent.isEmpty
                            ? fallbackName
                            : url.lastPathComponent
                    )))
                    return
                }

                if let data = item as? Data, !data.isEmpty {
                    completion(.success(ExtractedFile(data: data, fileName: fallbackName)))
                    return
                }

                tryLoadItem(at: index + 1)
            }
        }

        tryRepresentation(at: 0)
    }

    private func resolvedFileName(
        provider: NSItemProvider,
        sourceURL: URL,
        fallbackName: String
    ) -> String {
        let ext = sourceURL.pathExtension

        if let suggested = provider.suggestedName, !suggested.isEmpty {
            return ext.isEmpty ? suggested : suggested + "." + ext
        }

        return sourceURL.lastPathComponent.isEmpty
            ? fallbackName
            : sourceURL.lastPathComponent
    }

    // MARK: - Сохранение в общую папку

    private func saveToInbox(data: Data, fileName: String) -> Bool {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId
            )
        else {
            failureReasons.append("Нет доступа к общей папке приложения")
            return false
        }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: inbox,
                withIntermediateDirectories: true
            )

            let cleanName = fileName.replacingOccurrences(of: "/", with: "_")
            var destination = inbox.appendingPathComponent(cleanName)

            let base = destination.deletingPathExtension()
            let ext = destination.pathExtension
            var number = 2

            while FileManager.default.fileExists(atPath: destination.path) {
                destination = base.appendingPathExtension("\(number)" + (ext.isEmpty ? "" : "." + ext))
                number += 1
            }

            try data.write(to: destination)
            return true
        } catch {
            failureReasons.append("Ошибка сохранения: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Завершение

    private func reportResult() {
        if importedCount > 0 {
            statusLabel.text = "Файлов передано: \(importedCount)"
            openHostApp()
        } else {
            let message = failureReasons.isEmpty
                ? "Не удалось скопировать файл"
                : failureReasons.joined(separator: "\n")
            fail(message)
        }
    }

    private func openHostApp() {
        // Прямой open() из расширения запрещён системой,
        // поэтому открываем приложение через цепочку обработчиков.
        guard let url = URL(string: "playbook://shared-inbox") else {
            finish()
            return
        }

        var responder: UIResponder? = self

        while let currentResponder = responder {
            if currentResponder != self,
               currentResponder.responds(to: NSSelectorFromString("openURL:")) {
                currentResponder.perform(NSSelectorFromString("openURL:"), with: url)
                break
            }
            responder = currentResponder.next
        }

        finish()
    }

    private func fail(_ message: String) {
        statusLabel.text = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
