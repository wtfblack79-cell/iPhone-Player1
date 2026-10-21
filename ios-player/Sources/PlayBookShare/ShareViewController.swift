import UIKit

class ShareViewController: UIViewController {

    private struct ExtractedFile {
        let name: String
        let data: Data
    }

    private let statusLabel = UILabel()
    private let appGroupId = "group.com.personal.iphoneplayer"
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBlue
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        statusLabel.text = "Передача файлов…"
        view.addSubview(statusLabel)

        // Страховка: если система не ответит — закрываемся сами
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.close(with: "Не удалось передать файлы", after: 0.1)
        }

        extractAndDeliver()
    }

    // MARK: - Извлечение файлов

    private func extractAndDeliver() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            close(with: "Нет данных для передачи", after: 1.5)
            return
        }

        var providers: [NSItemProvider] = []
        for item in extensionItems {
            if let attachments = item.attachments {
                providers.append(contentsOf: attachments)
            }
        }

        if providers.isEmpty {
            close(with: "Файлы не найдены", after: 1.5)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [ExtractedFile] = []

        for provider in providers {
            group.enter()
            extractFile(from: provider) { file in
                lock.lock()
                if let file = file {
                    collected.append(file)
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let strongSelf = self else { return }

            if collected.isEmpty {
                strongSelf.close(with: "Не удалось прочитать файлы", after: 1.5)
                return
            }

            strongSelf.deliver(files: collected)
        }
    }

    private func extractFile(from provider: NSItemProvider, completion: @escaping (ExtractedFile?) -> Void) {
        let types = provider.registeredTypeIdentifiers

        let dataTypes = types.filter { $0 != "public.file-url" && $0 != "public.url" }
        let urlTypes = types.filter { $0 == "public.file-url" || $0 == "public.url" }

        tryDataPass(types: dataTypes, index: 0, provider: provider) { file in
            if let file = file {
                completion(file)
                return
            }

            self.tryURLPass(types: urlTypes, index: 0, provider: provider) { fallbackFile in
                completion(fallbackFile)
            }
        }
    }

    // Путь 1: прямое чтение содержимого файла
    private func tryDataPass(types: [String], index: Int, provider: NSItemProvider, completion: @escaping (ExtractedFile?) -> Void) {
        if index >= types.count {
            completion(nil)
            return
        }

        let type = types[index]

        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            if let url = url, let data = try? Data(contentsOf: url), !data.isEmpty {
                let name = self.fileNameFrom(url: url, type: type)
                DispatchQueue.main.async {
                    completion(self.encode(name: name, data: data))
                }
                return
            }

            self.tryDataPass(types: types, index: index + 1, provider: provider, completion: completion)
        }
    }

    // Путь 2: файловая ссылка
    private func tryURLPass(types: [String], index: Int, provider: NSItemProvider, completion: @escaping (ExtractedFile?) -> Void) {
        if index >= types.count {
            completion(nil)
            return
        }

        let type = types[index]

        provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
            var data: Data? = nil
            var name: String? = nil

            if let url = item as? URL, url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                data = try? Data(contentsOf: url)
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                name = url.lastPathComponent
            } else if let nsUrl = item as? NSURL, nsUrl.isFileURL, let path = nsUrl.path {
                data = try? Data(contentsOf: URL(fileURLWithPath: path))
                name = nsUrl.lastPathComponent
            } else if let directData = item as? Data {
                data = directData
            } else if let string = item as? String {
                if FileManager.default.fileExists(atPath: string) {
                    data = try? Data(contentsOf: URL(fileURLWithPath: string))
                    name = (string as NSString).lastPathComponent
                } else if let textData = string.data(using: .utf8) {
                    data = textData
                }
            }

            if let data = data, !data.isEmpty {
                let finalName = name ?? self.suggestedName(type: type)
                DispatchQueue.main.async {
                    completion(self.encode(name: finalName, data: data))
                }
                return
            }

            self.tryURLPass(types: types, index: index + 1, provider: provider, completion: completion)
        }
    }

    // MARK: - Имена файлов

    private func fileNameFrom(url: URL, type: String) -> String {
        var name = url.lastPathComponent

        if !name.contains(".") {
            if let ext = suggestedExtension(type: type) {
                name = name + "." + ext
            }
        }

        return name
    }

    private func suggestedName(type: String) -> String {
        if let ext = suggestedExtension(type: type) {
            return "Файл." + ext
        }
        return "Файл"
    }

    private func suggestedExtension(type: String) -> String? {
        let map: [String: String] = [
            "com.fictionbook.fb2": "fb2",
            "org.fb2": "fb2",
            "org.idpf.epub-container": "epub",
            "public.plain-text": "txt",
            "public.xml": "xml",
            "public.mp3": "mp3",
            "mpeg-4-audio": "m4a",
            "com.apple.m4a-audio": "m4a",
            "com.microsoft.waveform-audio": "wav",
            "public.aiff-audio": "aiff",
            "org.xiph.flac": "flac",
            "public.aac-audio": "aac"
        ]

        return map[type]
    }

    private func encode(name: String, data: Data) -> ExtractedFile? {
        if data.isEmpty {
            return nil
        }
        return ExtractedFile(name: name, data: data)
    }

    // MARK: - Передача

    private func deliver(files: [ExtractedFile]) {
        // Путь 1: общая папка App Group (на платной учётке)
        if let dir = inboxDirectory() {
            var savedCount = 0

            for file in files {
                let fileURL = dir.appendingPathComponent(uniqueFileName(file.name, in: dir))
                if (try? file.data.write(to: fileURL)) != nil {
                    savedCount += 1
                }
            }

            if savedCount > 0 {
                close(with: "Файлов передано: \(savedCount)", after: 1.2)
                openHostApp()
                return
            }
        }

        // Путь 2: системный буфер обмена (бесплатная учётка)
        let totalBytes = files.reduce(0) { $0 + $1.data.count }

        if totalBytes > 30 * 1024 * 1024 {
            close(with: "Файл слишком большой для шторки.\nИспользуйте «Копировать в PlayBook»", after: 2.5)
            return
        }

        var packed: [[String: Any]] = []
        for file in files {
            packed.append(["name": file.name, "data": file.data])
        }

        guard JSONSerialization.isValidJSONObject(packed),
              let json = try? JSONSerialization.data(withJSONObject: packed) else {
            close(with: "Не удалось упаковать файлы", after: 1.5)
            return
        }

        UIPasteboard.general.string = Self.payloadPrefix + json.base64EncodedString()
        close(with: "Файлов передано: \(files.count)", after: 1.2)
        openHostApp()
    }

    private func inboxDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }

        let dir = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    private func uniqueFileName(_ name: String, in directory: URL) -> String {
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

    // Открываем основное приложение через цепочку responders
    private func openHostApp() {
        guard let url = URL(string: "playbook://shared-inbox") else { return }

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                let selector = NSSelectorFromString("openURL:")
                if application.responds(to: selector) {
                    application.perform(selector, with: url as NSURL)
                }
                return
            }
            responder = current.next
        }
    }

    private func close(with message: String, after delay: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, !strongSelf.finished else { return }
            strongSelf.finished = true
            strongSelf.statusLabel.text = message

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
}
