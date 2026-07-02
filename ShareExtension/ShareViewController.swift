import UIKit
import SwiftUI

/// Principal class of the KlicShare extension (see Info.plist). Hosts the SwiftUI share
/// panel and owns the extension-context handshake: Send completes the request, Cancel (or
/// any unrecoverable state, e.g. no readable tokens) cancels it — never crashes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let root = ShareView(
            inputItems: items,
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                )
            }
        )

        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
