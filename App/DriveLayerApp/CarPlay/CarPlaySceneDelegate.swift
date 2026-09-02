import Foundation
import UIKit
#if canImport(CarPlay)
import CarPlay
#endif

/// CarPlay entry point.
///
/// CarPlay is a separate product surface, not a mirror of the phone. It shows a
/// tab bar over two glanceable tile screens — Vehicle and Ahead — plus a short list
/// of questions whose answers are already computed. No charts, no scrolling
/// telemetry, no interaction that needs more than a glance.
///
/// The templates used here are the ones a driving-task app may present. Everything
/// CarPlay-specific lives in this folder; nothing else in the app depends on it, so
/// the app builds and runs identically without the CarPlay entitlement — the scene
/// simply never connects. See docs/CARPLAY.md.
#if canImport(CarPlay)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var presenter: CarPlayPresenter?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let presenter = CarPlayPresenter(interfaceController: interfaceController)
        self.presenter = presenter
        presenter.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        presenter?.stop()
        presenter = nil
        self.interfaceController = nil
    }
}
#endif
