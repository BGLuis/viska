package app.viska.viska

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Canal de plataforma para anúncio BLE por UUID de serviço rotativo —
 * `docs/protocol.md` §9.1, Fase 6 F2.
 *
 * `flutter_blue_plus` cobre o papel central/scanner (`ble_scanner.dart`),
 * mas não advertising de forma confiável em todas as plataformas
 * (relatório da Fase 6, §3) — daí este canal próprio para o papel
 * periférico. O UUID rotativo vai sempre no campo de UUID de serviço do
 * pacote de advertising, **nunca** em manufacturer data: decisão 2.2 do
 * relatório — o iOS em segundo plano não anuncia manufacturer data, e o
 * UUID de serviço é o único campo que um scanner consegue procurar
 * exatamente enquanto o app do outro lado está fechado.
 *
 * Pedir a permissão de runtime (`BLUETOOTH_ADVERTISE` em Android 12+) é
 * responsabilidade do lado Dart, via `permission_handler` — mesma
 * convenção já usada para câmera/microfone. Se a permissão não tiver sido
 * concedida, `startAdvertising` do SO lança `SecurityException`, convertida
 * aqui num `Result.error` em vez de derrubar o app.
 *
 * Não verificado em hardware real ainda — só compilação. Ver Fase 6, §5 do
 * relatório: BLE só é validável com dois aparelhos físicos.
 */
class BleAdvertiserPlugin(private val context: Context) : MethodChannel.MethodCallHandler {
    private var advertiser: BluetoothLeAdvertiser? = null
    private var activeCallback: AdvertiseCallback? = null

    companion object {
        private const val CHANNEL_NAME = "viska/ble_advertiser"

        fun register(messenger: BinaryMessenger, context: Context) {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            channel.setMethodCallHandler(BleAdvertiserPlugin(context))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "startAdvertising" -> {
                val serviceUuid = call.argument<String>("serviceUuid")
                if (serviceUuid == null) {
                    result.error("bad_args", "serviceUuid ausente", null)
                    return
                }
                startAdvertising(serviceUuid, result)
            }
            "stopAdvertising" -> {
                stopAdvertisingInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun bluetoothManager(): BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private fun isSupported(): Boolean {
        val adapter = bluetoothManager()?.adapter ?: return false
        return adapter.isEnabled && adapter.isMultipleAdvertisementSupported
    }

    private fun startAdvertising(serviceUuid: String, result: MethodChannel.Result) {
        val adapter = bluetoothManager()?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("unsupported", "Bluetooth indisponível ou desligado", null)
            return
        }
        val bleAdvertiser = adapter.bluetoothLeAdvertiser
        if (bleAdvertiser == null) {
            result.error("unsupported", "Aparelho não suporta advertising BLE", null)
            return
        }

        stopAdvertisingInternal()

        val settings =
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(false)
                .build()

        val data =
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(UUID.fromString(serviceUuid)))
                .build()

        val callback =
            object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                    result.success(null)
                }

                override fun onStartFailure(errorCode: Int) {
                    advertiser = null
                    activeCallback = null
                    result.error("advertise_failed", "Falha ao anunciar (código $errorCode)", null)
                }
            }

        try {
            bleAdvertiser.startAdvertising(settings, data, callback)
            advertiser = bleAdvertiser
            activeCallback = callback
        } catch (e: SecurityException) {
            result.error("permission_denied", "Sem permissão BLUETOOTH_ADVERTISE", e.message)
        }
    }

    private fun stopAdvertisingInternal() {
        val bleAdvertiser = advertiser
        val callback = activeCallback
        advertiser = null
        activeCallback = null
        if (bleAdvertiser != null && callback != null) {
            try {
                bleAdvertiser.stopAdvertising(callback)
            } catch (e: SecurityException) {
                // Sem permissão para sequer parar — nada a fazer além de
                // esquecer a referência, já feito acima.
            }
        }
    }
}
