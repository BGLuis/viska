package app.viska.viska

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Canais de plataforma próprios — Fase 6, F2 (BLE) e F4 (Wi-Fi
        // Aware). Registrar os dois incondicionalmente é seguro mesmo em
        // aparelhos sem suporte: cada `isSupported()` do lado Dart decide
        // se usa o canal, o registro em si não exige o rádio presente.
        BleAdvertiserPlugin.register(messenger, applicationContext)
        WifiAwarePlugin.register(messenger, applicationContext)
    }
}
