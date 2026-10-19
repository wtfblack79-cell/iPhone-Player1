import UIKit

class ShareViewController: UIViewController {

    private let label = UILabel()
    private var didProcess = false
    private let groupID = "group.com.personal.iphoneplayer"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBlue
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 18)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "Расширение запущено"
        label.frame = CGRect(x: 20, y: 150, width: 300, height: 200)
        label.autoresizingMask = [.flexibleWidth]
        view.addSubview(label)

        findAndLoad()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if let s = self, !s.didProcess {
                s.show("Файл не пришёл за 30 сек")
            }
        }
    }

    private func show(_ text: String) {
        DispatchQueue.main.async { self.label.text = text }
    }

    private func findAndLoad() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        let types = [
            "public.audio", "public.mp3", "public.mpeg-4-audio",
            "com.apple.m4a-audio", "com.apple.m4b-audio",
            "public.aac-audio", "com.microsoft.waveform-audio",
            "public.aiff-audio", "com.apple.coreaudio-format",
            "org.xiph.flac"
        ]

        guard let att = attachments.first(where: { a in
            types.contains(where: { a.hasItemConformingToTypeIdentifier($0) })
        }) else {
            show("Аудио среди вложений не найдено")
            closeSoon()
            return
        }

        let type = types.first(where: {
            att.hasItemConformingToTypeIdentifier($0)
        }) ?? "public.audio"
        show("Получаю файл")

        att.loadItem(forTypeIdentifier: type, options: nil) { [weak self] obj, _ in
            guard let self = self else { return }
            DispatchQueue.global().async {
                self.save(obj, suggested: att.suggestedName ?? "")
            }
        }
    }

    private func save(_ obj: Any?, suggested: String) {
        didProcess = true

        var source: URL?

        if let url = obj as? URL {
            source = url
        } else if let data = obj as? Data {
            let ext = (suggested as NSString).pathExtension
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mp3" : ext)
            do {
                try data.write(to: tmp)
                source = tmp
            } catch {
                show("Ошибка записи: \(error.localizedDescription)")
                closeSoon()
                return
            }
        }

        guard let src = source,
              FileManager.default.fileExists(atPath: src.path) else {
            show("Файл не удалось прочитать")
            closeSoon()
            return
        }

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            show("APP GROUP НЕДОСТУПЕН")
            closeSoon()
            return
        }

        let folder = container.appendingPathComponent("SharedAudio")
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )

        var name = src.lastPathComponent
        if name.isEmpty { name = suggested.isEmpty ? "audio.mp3" : suggested }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 1
        var target = folder.appendingPathComponent(name)
        while FileManager.default.fileExists(atPath: target.path) {
            i += 1
            target = folder.appendingPathComponent("\(base) (\(i)).\(ext)")
        }

        do {
            try FileManager.default.copyItem(at: src, to: target)
            UserDefaults(suiteName: groupID)?.set(
                target.path, forKey: "lastSharedAudioPath"
            )
            show("Файл сохранён: \(name)")
        } catch {
            show("Ошибка копирования: \(error.localizedDescription)")
        }

        closeSoon()
    }

    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
