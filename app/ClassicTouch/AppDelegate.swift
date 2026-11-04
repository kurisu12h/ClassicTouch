// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The phone does not auto-lock while the emulator screen is up (RootViewController.show): locking during a benchmark skews the CPU numbers
        true
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let vc = RootViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        root = vc
    }

    // qemu-ios-ui.h: iOS kills a process that sends GL commands in the background, so the foreground flag has to be
    // cleared as early as willResignActive. The VM pauses too (pulling down Control Center or Notification Center also
    // triggers willResignActive; the screen freezes, and the VM continues on return).
    func sceneWillResignActive(_ scene: UIScene) { root?.setAppActive(false) }
    func sceneDidBecomeActive(_ scene: UIScene) { root?.setAppActive(true) }
}
