
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let appGroup = "group.com.personal.iphoneplayer"

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = "Передача аудио в PlayBook…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            label.centerYAnchor.constraint(
                equalTo: view.centerYAnchor
            ),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 20
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -20
            )
        ])

        receiveAudio()
    }

    private func receiveAudio() {
        guard
            let item = extensionContext?.inputItems
                .compactMap({ $0 as? NSExtensionItem })
                .flatMap({ $0.attachments ?? [] })
                .first(where: {
                    $0.hasItemConformingToTypeIdentifier(
                        UTType.audio.identifier
                    )
                })
        else {
            finish()
            return
        }

        item.loadFileRepresentation(
            forTypeIdentifier: UTType.audio.identifier
        ) { [weak self] sourceURL, error in

            guard
                error == nil,
                let sourceURL,
                let sharedURL = FileManager.default
                    .containerURL(
                        forSecurityApplicationGroupIdentifier:
                            self?.appGroup ?? ""
                    )
            else {
                self?.finish()
                return
            }

            do {
                let folder = sharedURL.appendingPathComponent(
                    "IncomingAudio",
                    isDirectory: true
                )

                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )

                let fileExtension = sourceURL.pathExtension.isEmpty
                    ? "m4a"
                    : sourceURL.pathExtension

                let destination = folder
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension)

                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destination
                )

                UserDefaults(
                    suiteName: self?.appGroup
                )?.set(
                    destination.path,
                    forKey: "playbook.pendingSharedAudio"
                )

            } catch {
                // Не завершаем передачу как успешную,
                // если файл не удалось сохранить.
            }

            self?.finish()
        }
    }

    private func finish() {
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(
                returningItems: nil
            )
        }
    }
}
