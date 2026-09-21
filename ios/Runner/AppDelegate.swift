import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private let privacyBlurTag = 99991

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    // Oculta a tela no app switcher do iOS (Fase 7, F0 / D13) aplicando um blur
    // sobre a janela antes de ir para segundo plano.
    guard let window = self.window, window.viewWithTag(privacyBlurTag) == nil else { return }
    let blurEffect = UIBlurEffect(style: .dark)
    let blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.frame = window.bounds
    blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blurEffectView.tag = privacyBlurTag
    window.addSubview(blurEffectView)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    // Remove a cobertura de privacidade ao retornar ao primeiro plano.
    self.window?.viewWithTag(privacyBlurTag)?.removeFromSuperview()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Canais de plataforma próprios — Fase 6, F2 (BLE) e F5
    // (MultipeerConnectivity). Mesmo padrão de
    // `registrar(forPlugin:).messenger()` que todo plugin Flutter usa em
    // `register(with registrar:)`.
    let registry = engineBridge.pluginRegistry
    if let bleRegistrar = registry.registrar(forPlugin: "BleAdvertiser") {
      BleAdvertiser.register(with: bleRegistrar.messenger())
    }
    if let multipeerRegistrar = registry.registrar(forPlugin: "MultipeerPlugin") {
      MultipeerPlugin.register(with: multipeerRegistrar.messenger())
    }
  }
}
