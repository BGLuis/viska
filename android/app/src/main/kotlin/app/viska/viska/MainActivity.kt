package app.viska.viska

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FLAG_SECURE ligado por padrão (Fase 7, F0 / D13) — protege contra captura
        // de tela e oculta a miniatura da tela no seletor de aplicativos recentes.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Canais de plataforma próprios — Fase 6, F2 (BLE) e F4 (Wi-Fi
        // Aware). Registrar os dois incondicionalmente é seguro mesmo em
        // aparelhos sem suporte: cada `isSupported()` do lado Dart decide
        // se usa o canal, o registro em si não exige o rádio presente.
        BleAdvertiserPlugin.register(messenger, applicationContext)
        WifiAwarePlugin.register(messenger, applicationContext)
        // Canal de segurança de plataforma — Fase 7, F0/F1/F2.
        SecurityPlugin.register(messenger, this)
        // MulticastLock — necessário para mDNS funcionar no Android
        // (docs/protocol.md §9.2); declarar CHANGE_WIFI_MULTICAST_STATE no
        // AndroidManifest não é suficiente sem acquire() em runtime.
        MulticastLockPlugin.register(messenger, applicationContext)
    }
}
