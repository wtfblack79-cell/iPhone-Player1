import UIKit

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBlue
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "PlayBook: кнопка-иконка не работает на бесплатной учётке.\n\nИспользуйте пункт \"Копировать в PlayBook\" в списке действий шторки"
        statusLabel.frame = CGRect(x: 20, y: 150, width: 300, height: 250)
        statusLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(statusLabel)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
