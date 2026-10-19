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

    private let statusLabel = UILabel()
    private var didProcess = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBlue
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 18)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "PlayBook: расширение запущено"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 200)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)

        handleSharedItems()

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, !self.didProcess else { return }
            self.updateStatus("Файл не пришёл за 30 секунд")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.finish()
            }
        }
    }

    private func handleSharedItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            updateStatus("Не удалось получить элементы")
            delayedFinish()
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                if let type = audioTypes.first(where: {
                    attachment.hasItemConformingToTypeIdentifier($0)
                }) {
                    updateStatus("Получаю файл: 
