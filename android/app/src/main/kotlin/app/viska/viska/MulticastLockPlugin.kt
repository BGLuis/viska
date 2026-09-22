package app.viska.viska

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Canal de plataforma para [WifiManager.MulticastLock] — necessário para que
 * o NsdManager receba pacotes mDNS multicast no Android (docs/protocol.md §9.2).
 *
 * Declarar CHANGE_WIFI_MULTICAST_STATE no AndroidManifest não é suficiente:
 * o lock precisa ser adquirido em runtime antes de qualquer browse/advertise
 * mDNS, e liberado quando a descoberta termina. Sem o lock, o driver Wi-Fi
 * filtra os pacotes multicast antes de chegarem ao processo.
 *
 * `setReferenceCounted(false)` — um único acquire/release por ciclo, sem
 * contagem de referência. O lado Dart garante acquire antes e release depois
 * de cada `LanTransport.connect()`.
 */
class MulticastLockPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    private var lock: WifiManager.MulticastLock? = null

    companion object {
        private const val CHANNEL_NAME = "viska/multicast_lock"
        private const val LOCK_TAG = "viska_mdns"

        fun register(messenger: BinaryMessenger, context: Context) {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            channel.setMethodCallHandler(MulticastLockPlugin(context))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> acquire(result)
            "release" -> release(result)
            else -> result.notImplemented()
        }
    }

    private fun acquire(result: MethodChannel.Result) {
        try {
            if (lock?.isHeld == true) {
                // Já adquirido — idempotente.
                result.success(null)
                return
            }
            val wm = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wm == null) {
                // Dispositivo sem Wi-Fi — não é erro fatal: mDNS simplesmente
                // não vai funcionar, e o fallback WebRTC ainda está disponível.
                result.error("no_wifi", "WifiManager não disponível", null)
                return
            }
            val l = wm.createMulticastLock(LOCK_TAG)
            l.setReferenceCounted(false)
            l.acquire()
            lock = l
            result.success(null)
        } catch (e: Exception) {
            result.error("acquire_failed", e.message, null)
        }
    }

    private fun release(result: MethodChannel.Result) {
        try {
            lock?.let {
                if (it.isHeld) it.release()
            }
            lock = null
            result.success(null)
        } catch (e: Exception) {
            // Liberar um lock já liberado não é erro fatal — expira com o processo.
            result.success(null)
        }
    }
}
