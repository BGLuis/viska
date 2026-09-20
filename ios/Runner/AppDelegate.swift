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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Canais de plataforma próprios — Fase 6, F2 (BLE) e F5
    // (MultipeerConnectivity). Mesmo padrão de
    // `registrar(forPlugin:).messenger()` que todo plugin Flutter usa em
    // `register(with registrar:)`.
    let bleRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "BleAdvertiser")
    BleAdvertiser.register(with: bleRegistrar.messenger())
    let multipeerRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MultipeerPlugin")
    MultipeerPlugin.register(with: multipeerRegistrar.messenger())
  }
}
