import UIKit
import UniformTypeIdentifiers

// Расширение "Поделиться" для PlayBook.
// Собирает файлы из шторки, кладёт их в общую папку App Group
// (или, на бесплатной учётке, в буфер обмена) и открывает приложение.

struct ExtractedFile {
    let data: Data
    let fileName: String
}

final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let appGroupID = "group.com.personal.iphoneplayer"
    private let resultLock = NSLock()
    private var resultFiles: [ExtractedFile] = []
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBlue
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Передача файлов…"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)

        startTimeout()
        collectFiles()
    }

    deinit {
        timeoutWork?.cancel()
    }

    // MARK: - Сбор файлов из шторки

    private func collectFiles() {
        guard let context = extensionContext,
              let items = context.inputItems as? [NSExtensionItem] else {
            fail("Файлы не найдены")
            return
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            fail("Файлы не найдены")
            return
        }

        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            extractFile(from: provider) { [weak self] file in
                if let file {
                    self?.resultLock.lock()
                    self?.resultFiles.append(file)
                    self?.resultLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !self.finished else { return }
            if self.resultFiles.isEmpty {
                self.fail("Не удалось прочитать файлы")
            } else {
                self.deliver(self.resultFiles)
            }
        }
    }

    // Перебирает все типы, которые система реально отдала для файла
    private func extractFile(from provider: NSItemProvider,
                             completion: @escaping (ExtractedFile?) -> Void) {
        let types = preferredTypes(from: provider.registeredTypeIdentifiers)
        tryLoad(0)

        func tryLoad(_ index: Int) {
            guard index < types.count else {
                completion(nil)
                return
            }

            let typeID = types[index]
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                if let url, let data = try? Data(contentsOf: url) {
                    let file = ExtractedFile(
                        data: data,
                        fileName: self.suggestedName(for: provider, typeID: typeID)
                    )
                    completion(file)
                } else {
                    self.loadFallback(provider: provider, typeID: typeID) { file in
                        if let file {
                            completion(file)
                        } else {
                            tryLoad(index + 1)
                        }
                    }
                }
            }
        }
    }

    private func loadFallback(provider: NSItemProvider,
                              typeID: String,
                              completion: @escaping (ExtractedFile?) -> Void) {
        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, error in
            var file: ExtractedFile?

            if let url = item as? URL, let data = try? Data(contentsOf: url) {
                file = ExtractedFile(data: data, fileName: self.suggestedName(for: provider, typeID: typeID))
            } else if let data = item as? Data {
                file = ExtractedFile(data: data, fileName: self.suggestedName(for: provider, typeID: typeID))
            } else if let url = (item as? NSURL)?.fileURL, let data = try? Data(contentsOf: url) {
                file = ExtractedFile(data: data, fileName: self.suggestedName(for: provider, typeID: typeID))
            } else if let path = item as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                file = ExtractedFile(data: data, fileName: self.suggestedName(for: provider, typeID: typeID))
            }

            completion(file)
        }
    }

    // Сначала типы, понятные системе как данные/файлы, затем остальные
    private func preferredTypes(from types: [String]) -> [String] {
        let clean = types.filter { !$0.isEmpty }
        let strong = clean.filter { UTType($0)?.conforms(to: .data) == true }
        let weak = clean.filter { !strong.contains($0) }
        return strong + weak
    }

    private func suggestedName(for provider: NSItemProvider, typeID: String) -> String {
        if let name = provider.suggestedName, !name.isEmpty {
            return name
        }
        let ext = UTType(typeID)?.preferredFilenameExtension ?? "dat"
        return "файл." + ext
    }

    // MARK: - Доставка

    private func deliver(_ files: [ExtractedFile]) {
        let saved = saveToAppGroup(files) || saveToPasteboard(files)

        if saved {
            statusLabel.text = files.count == 1
                ? "Файлов передано: 1"
                : "Файлов передано: \(files.count)"
            openHostApp()
            finish(after: 1.2)
        } else {
            fail("Не удалось сохранить файлы")
        }
    }

    private func saveToAppGroup(_ files: [ExtractedFile]) -> Bool {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            // На бесплатной учётке App Group недоступна — уйдём через буфер
            return false
        }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            for file in files {
                let target = uniqueURL(for: inbox.appendingPathComponent(file.fileName))
                try file.data.write(to: target)
            }
            return true
        } catch {
            return false
        }
    }

    private func saveToPasteboard(_ files: [ExtractedFile]) -> Bool {
        var payload: [[String: Any]] = []
        for file in files {
            payload.append([
                "name": file.fileName,
                "data": file.data
            ])
        }

        guard let packed = try? PropertyListSerialization
            .data(fromPropertyList: payload, format: .binary, options: 0) else {
            return false
        }

        UIPasteboard.general.setItems(
            [[pasteboardKey: packed]],
            options: [UIPasteboard.OptionsKey.expirationDate: Date().addingTimeInterval(600)]
        )
        return true
    }

    private func uniqueURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for index in 1...999 {
            let candidate = directory
                .appendingPathComponent("\(baseName) (\(index))")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - Открытие приложения и завершение

    private func openHostApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                break
            }
            responder = current.next
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        statusLabel.text = message
        finish(after: 2.0)
    }

    private func finish(after delay: TimeInterval) {
        finished = true
        timeoutWork?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    // Страховка: шторка закроется даже если система не ответит
    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }
}
