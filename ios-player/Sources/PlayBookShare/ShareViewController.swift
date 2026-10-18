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

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                for type in audioTypes where attachment.hasItemConformingToTypeIdentifier(type) {
                    attachment.loadItem(forTypeIdentifier: type, options: nil) { [weak self] object, _ in
                        DispatchQueue.main.async {
                            self?.processItem(object, suggestedName: attachment.suggestedName ?? "")
                        }
                    }
                    return
                }
            }
        }
        finish()
    }

    private func processItem(_ item: Any?, suggestedName: String) {
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
                finish()
                return
            }
        }

        guard let source = sourceURL else {
            finish()
            return
        }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.personal.iphoneplayer"
        ) else {
            finish()
            return
        }

        let sharedFolder = containerURL.appendingPathComponent("SharedAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)

        var counter = 1
        var targetName = source.lastPathComponent
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
            finish()
            return
        }

        openMainApp()
    }

    private func openMainApp() {
        guard let url = URL(string: "playbook://shared") else {
            finish()
            return
        }

        let selectorOpenURL = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selectorOpenURL), current !== self {
                current.perform(selectorOpenURL, with: url)
                break
            }
            responder = current.next
        }

        finish()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
