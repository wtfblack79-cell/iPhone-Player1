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
            let name = suggestedName as NSString
            let ext = name.pathExtension.isEmpty ? "mp3" : name.pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
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

        var destination = sharedFolder.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        let baseName = destination.deletingPathExtension().lastPathComponent
        let fileExt = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = sharedFolder.appendingPathComponent("
