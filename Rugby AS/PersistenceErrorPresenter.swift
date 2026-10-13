import Combine
import SwiftUI
import UIKit

/// Present above the currently open editor, including nested SwiftUI sheets.
struct PersistenceErrorPresenter: ViewModifier {
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: AppPersistence.failureNotification)
            .receive(on: DispatchQueue.main)) { notification in
            guard let message = notification.userInfo?["message"] as? String,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            if let alert = presenter as? UIAlertController { alert.message = message; return }
            let alert = UIAlertController(title: "保存できませんでした", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "閉じる", style: .default))
            presenter.present(alert, animated: true)
        }
    }
}
