import UIKit

class ShareViewController: UIViewController {

    private let audioTypes = [
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

    private var didProcess = false

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()

        // Страховка: если файл так и не пришёл за 30 секунд — закрываем шторку,
        // чтобы Диск не висел вечно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, !self.didProcess else { return }
            self.finish()
        }
    }

    private func handleSharedItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                if let type = audioTypes.first(where: {
                    attachment.hasItemConformingToTypeIdentifier($0)
                }) {
                    attachment.loadItem(forTypeIdentifier: type, options: nil) {
                        [weak self] object, _ in
                        guard let self = self else { return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.processItem(object,
                                             suggestedName: attachment.suggestedName ?? "")
                        }
                    }
                    // ВАЖНО: здесь больше НЕТ finish() —
                    // закрываем шторку только после сохранения файла.
                    return
                }
            }
        }

        // Сюда попадаем, только если среди вложений нет ни одного аудиофайла
        finish()
    }

    private func processItem(_ item: Any?, suggestedName: String) {
        didProcess = true

        var sourceURL: URL?

        if let url = item as? URL {
            sourceURL = url
        } else if let data = item as? Data {
            let ext = (suggestedName as NSString).pathExtension
            let realExt = ext.isEmpty ? "mp3" : ext
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(realExt)
            do {
                try data.write(to: tempURL)
                sourceURL = tempURL
            } catch {
                DispatchQueue.main.async { self.finish() }
                return
            }
        }

        guard let source = sourceURL else {
            DispatchQueue.main.async { self.finish() }
            return
        }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.personal.iphoneplayer"
        ) else {
            DispatchQueue.main.async { self.finish() }
            return
        }

        let sharedFolder = containerURL.appendingPathComponent("SharedAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedFolder,
                                                 withIntermediateDirectories: true)

        var counter = 1
        var targetName = source.lastPathComponent
        if targetName.isEmpty {
            targetName = "audiobook.mp3"
        }
        let baseName = (targetName as NSString).deletingPathExtension
        let fileExt = (targetName as NSString).pathExtension

        while FileManager.default.fileExists(
            atPath: sharedFolder.appendingPathComponent(targetName).path
        ) {
            targetName = baseName + " (" + String(counter) + ")." + fileExt
            counter += 1
        }

        let destination = sharedFolder.appendingPathComponent(targetName)

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            UserDefaults(suiteName: "group.com.personal.iphoneplayer")?
                .set(destination.path, forKey: "lastSharedAudioPath")
        } catch {
            DispatchQueue.main.async { self.finish() }
            return
        }

        DispatchQueue.main.async {
            self.tryOpenMainApp()
            self.finish()
        }
    }

    private func tryOpenMainApp() {
        guard let url = URL(string: "playbook://shared") else { return }
        let selectorOpenURL = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selectorOpenURL), current !== self {
                current.perform(selectorOpenURL, with: url)
                break
            }
            responder = current.next
        }
    }

    private func finish() {
        didProcess = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
