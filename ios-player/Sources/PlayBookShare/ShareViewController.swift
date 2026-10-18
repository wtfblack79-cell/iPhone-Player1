import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            completeRequest()
            return
        }

        let audioTypes = [
            "public.audio",
            "public.mp3",
            "public.mpeg-4-audio",
            "com.apple.m4a-audio",
            "com.microsoft.waveform-audio",
            "public.aiff-audio"
        ]

        for attachment in attachments {
            for type in audioTypes {
                if attachment.hasItemConformingToTypeIdentifier(type) {
                    attachment.loadItem(forTypeIdentifier: type, options: nil) { [weak self] (item, error) in
                        self?.processItem(item)
                    }
                    return
                }
            }
        }

        completeRequest()
    }

    private func processItem(_ item: Any?) {
        var fileURL: URL?

        if let url = item as? URL {
            fileURL = url
        } else if let data = item as? Data {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp3")
            try? data.write(to: tempURL)
            fileURL = tempURL
        }

        guard let sourceURL = fileURL else {
            completeRequest()
            return
        }

        // Копируем файл в общую папку
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.personal.iphoneplayer"
        ) else {
            completeRequest()
            return
        }

        let sharedFolder = containerURL.appendingPathComponent("SharedAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)

        let destinationURL = sharedFolder.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            // Запоминаем путь
            UserDefaults(suiteName: "group.com.personal.iphoneplayer")?
                .set(destinationURL.path, forKey: "lastSharedAudioPath")

            openMainApp()
        } catch {
            completeRequest()
        }
    }

    private func openMainApp() {
        let url = URL(string: "playbook://shared")!

        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                break
            }
            responder = r.next
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.completeRequest()
        }
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
