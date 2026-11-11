package app.viska.viska

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Canal de plataforma que liga e desliga o [TransferForegroundService]. A
 * contagem de usos (seletor + transferências) fica no lado Dart: aqui só
 * chega `start` no primeiro uso e `stop` depois do último.
 */
class TransferServicePlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL_NAME = "viska/transfer_service"

        fun register(messenger: BinaryMessenger, context: Context) {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            channel.setMethodCallHandler(TransferServicePlugin(context))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> stop(result)
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        try {
            context.startForegroundService(Intent(context, TransferForegroundService::class.java))
            result.success(null)
        } catch (e: Exception) {
            // O Android 12+ recusa iniciar serviço em primeiro plano a partir do
            // segundo plano. O Dart trata como "sem serviço": a transferência
            // segue sem a proteção, como seguia antes dele.
            result.error("start_failed", e.javaClass.simpleName, null)
        }
    }

    private fun stop(result: MethodChannel.Result) {
        context.stopService(Intent(context, TransferForegroundService::class.java))
        result.success(null)
    }
}
