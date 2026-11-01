// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 模拟器画面开着时不自动锁屏（RootViewController.show）：测速时锁屏会让 CPU 数据失真
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

    // qemu-ios-ui.h：iOS 会杀掉在后台发 GL 命令的进程，前台标志要在 willResignActive 时就清掉。
    // 同时暂停虚拟机（拉下控制中心、通知中心时也会 willResignActive，这时画面停住，回来继续）。
    func sceneWillResignActive(_ scene: UIScene) { root?.setAppActive(false) }
    func sceneDidBecomeActive(_ scene: UIScene) { root?.setAppActive(true) }
}
