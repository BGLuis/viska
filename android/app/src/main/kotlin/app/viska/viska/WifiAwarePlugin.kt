package app.viska.viska

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataOutputStream
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/**
 * Canal de plataforma para Wi-Fi Aware — `docs/protocol.md` §9 (mesma
 * família do beacon BLE/mDNS), Fase 6 F4. Carrega dados de verdade (ao
 * contrário de BLE, que só descobre): o nome de serviço publicado/assinado
 * é o beacon em hex, igual à convenção de nome de instância mDNS
 * (`docs/protocol.md` §9.2) — reaproveitada aqui, não uma terceira
 * convenção nova.
 *
 * Fluxo (papéis espelham `LanTransport`: passivo publica, ativo assina):
 * 1. Passivo (`publish`): liga um `ServerSocket` de porta efêmera antes de
 *    publicar, e embute essa porta nos 2 primeiros bytes de
 *    `serviceSpecificInfo` — é como o lado ativo, depois de montar o
 *    caminho de dados, sabe em que porta discar.
 * 2. Ativo (`subscribe`): ao descobrir o serviço (`onServiceDiscovered`),
 *    lê a porta de `serviceSpecificInfo` e manda uma mensagem ao publicador
 *    (`sendMessage`) — é o único jeito da API de o publicador aprender o
 *    `PeerHandle` de quem quer se conectar (publicar não gera esse dado
 *    sozinho).
 * 3. Os dois lados então pedem a rede (`ConnectivityManager.requestNetwork`
 *    com `WifiAwareNetworkSpecifier` para o `PeerHandle` um do outro).
 * 4. Quando a rede fica disponível, o ativo disca um `Socket` para o
 *    endereço IPv6 do par (`WifiAwareNetworkInfo.peerIpv6Addr`) na porta
 *    aprendida no passo 2; o passivo aceita no `ServerSocket` já ligado.
 * 5. Bytes crus trafegam pelo `EventChannel` como `dataReceived` — quem
 *    aplica `wire::framing`/o preâmbulo de canal (control/file) é o lado
 *    Dart (`wifi_aware_transport.dart`), exatamente como em `LanTransport`.
 *
 * **Não verificado em hardware real.** Escrito por leitura da API pública
 * do Android (`android.net.wifi.aware`) — nenhum emulador reproduz Wi-Fi
 * Aware, e esta máquina não tem um aparelho Android conectado com câmera
 * utilizável para o fluxo completo de dois pares. Ver `CLAUDE.md` (ambiente
 * de desenvolvimento) e Fase 6, §5/§6 do relatório.
 */
class WifiAwarePlugin(private val context: Context) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null
    private var awareSession: WifiAwareSession? = null
    private var discoverySession: DiscoverySession? = null
    private var peerHandle: PeerHandle? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var serverSocket: ServerSocket? = null
    private var dataSocket: Socket? = null
    private val messageIdSeq = AtomicInteger(1)

    companion object {
        private const val METHOD_CHANNEL = "viska/wifi_aware"
        private const val EVENT_CHANNEL = "viska/wifi_aware/events"

        fun register(messenger: BinaryMessenger, context: Context) {
            val instance = WifiAwarePlugin(context)
            MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(instance)
            EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(instance)
        }
    }

    // ---- MethodChannel ----------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isSupported" -> result.success(isSupported())
                "publish" -> {
                    val serviceName = call.argument<String>("serviceName")
                    if (serviceName == null) {
                        result.error("bad_args", "serviceName ausente", null)
                        return
                    }
                    publish(serviceName, result)
                }
                "subscribe" -> {
                    val serviceName = call.argument<String>("serviceName")
                    if (serviceName == null) {
                        result.error("bad_args", "serviceName ausente", null)
                        return
                    }
                    subscribe(serviceName, result)
                }
                "send" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("bad_args", "bytes ausente", null)
                        return
                    }
                    send(bytes, result)
                }
                "close" -> {
                    closeAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("plugin_exception", e.message, null)
        }
    }

    private fun sendEvent(event: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            try {
                eventSink?.success(event)
            } catch (_: Exception) {}
        }
    }

    private fun isSupported(): Boolean {
        return try {
            val hasFeature =
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
            val manager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
            if (!hasFeature || manager == null || !manager.isAvailable) {
                return false
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.NEARBY_WIFI_DEVICES,
                ) == PackageManager.PERMISSION_GRANTED
            } else {
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED
            }
        } catch (e: Exception) {
            false
        }
    }

    // ---- Publicador (passivo) ----------------------------------------------

    private fun publish(serviceName: String, result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (manager == null || !manager.isAvailable) {
            result.error("unsupported", "Wi-Fi Aware indisponível", null)
            return
        }

        val socket =
            try {
                ServerSocket(0).also { it.reuseAddress = true }
            } catch (e: Exception) {
                result.error("socket_failed", "Não foi possível abrir a porta local", e.message)
                return
            }
        serverSocket = socket
        acceptIncoming(socket)

        val portBytes = ByteBuffer.allocate(2).putShort(socket.localPort.toShort()).array()

        try {
            manager.attach(
                object : AttachCallback() {
                    override fun onAttached(session: WifiAwareSession) {
                        awareSession = session
                        val config =
                            PublishConfig.Builder()
                                .setServiceName(serviceName)
                                .setServiceSpecificInfo(portBytes)
                                .build()
                        try {
                            session.publish(
                                config,
                                object : DiscoverySessionCallback() {
                                    override fun onPublishStarted(session: PublishDiscoverySession) {
                                        discoverySession = session
                                        result.success(null)
                                    }

                                    override fun onMessageReceived(peer: PeerHandle, message: ByteArray?) {
                                        peerHandle = peer
                                        requestNetwork(peer, isResponder = true)
                                        sendEvent(mapOf("event" to "serviceDiscovered"))
                                    }

                                    override fun onSessionConfigFailed() {
                                        result.error("publish_failed", "Falha ao publicar o serviço", null)
                                    }
                                },
                                null,
                            )
                        } catch (e: Exception) {
                            result.error("publish_failed", e.message, null)
                        }
                    }

                    override fun onAttachFailed() {
                        result.error("attach_failed", "Falha ao anexar à sessão Wi-Fi Aware", null)
                    }
                },
                null,
            )
        } catch (e: Exception) {
            result.error("attach_exception", e.message, null)
        }
    }

    // ---- Assinante (ativo) --------------------------------------------------

    private fun subscribe(serviceName: String, result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (manager == null || !manager.isAvailable) {
            result.error("unsupported", "Wi-Fi Aware indisponível", null)
            return
        }

        try {
            manager.attach(
                object : AttachCallback() {
                    override fun onAttached(session: WifiAwareSession) {
                        awareSession = session
                        val config = SubscribeConfig.Builder().setServiceName(serviceName).build()
                        try {
                            session.subscribe(
                                config,
                                object : DiscoverySessionCallback() {
                                    override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
                                        discoverySession = session
                                        result.success(null)
                                    }

                                    override fun onServiceDiscovered(
                                        peer: PeerHandle,
                                        serviceSpecificInfo: ByteArray?,
                                        matchFilter: MutableList<ByteArray>?,
                                    ) {
                                        peerHandle = peer
                                        val port =
                                            if (serviceSpecificInfo != null && serviceSpecificInfo.size >= 2) {
                                                ByteBuffer.wrap(serviceSpecificInfo).short.toInt() and 0xffff
                                            } else {
                                                null
                                            }
                                        sendEvent(mapOf("event" to "serviceDiscovered"))

                                        val session2 = discoverySession
                                        if (session2 != null && port != null) {
                                            pendingPort = port
                                            // Avisa o publicador para que ele aprenda nosso
                                            // `PeerHandle` (ver `onMessageReceived` acima) —
                                            // só depois disso os dois lados conseguem pedir
                                            // a mesma rede.
                                            try {
                                                session2.sendMessage(peer, messageIdSeq.getAndIncrement(), ByteArray(0))
                                            } catch (_: Exception) {}
                                        }
                                    }

                                    override fun onMessageSendSucceeded(messageId: Int) {
                                        val peer = peerHandle
                                        if (peer != null) {
                                            requestNetwork(peer, isResponder = false)
                                        }
                                    }

                                    override fun onSessionConfigFailed() {
                                        result.error("subscribe_failed", "Falha ao assinar o serviço", null)
                                    }
                                },
                                null,
                            )
                        } catch (e: Exception) {
                            result.error("subscribe_failed", e.message, null)
                        }
                    }

                    override fun onAttachFailed() {
                        result.error("attach_failed", "Falha ao anexar à sessão Wi-Fi Aware", null)
                    }
                },
                null,
            )
        } catch (e: Exception) {
            result.error("attach_exception", e.message, null)
        }
    }

    private var pendingPort: Int? = null

    // ---- Caminho de dados ---------------------------------------------------

    private fun requestNetwork(peer: PeerHandle, isResponder: Boolean) {
        val session = discoverySession ?: return
        val specifier =
            WifiAwareNetworkSpecifier.Builder(session, peer).build()
        val request =
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(specifier)
                .build()

        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val callback =
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (isResponder) {
                        // O `ServerSocket` já está ligado (`publish`); só falta
                        // esperar `accept()` — feito em `acceptIncoming`.
                        sendEvent(mapOf("event" to "sessionEstablished"))
                        return
                    }
                    val capabilities = connectivityManager.getNetworkCapabilities(network)
                    val info = capabilities?.transportInfo as? WifiAwareNetworkInfo
                    val address = info?.peerIpv6Addr
                    val port = pendingPort
                    if (address == null || port == null) {
                        sendEvent(
                            mapOf("event" to "connectionLost", "reason" to "sem endereço do par"),
                        )
                        return
                    }
                    try {
                        val socket = network.socketFactory.createSocket(address, port)
                        dataSocket = socket
                        readIncoming(socket.getInputStream())
                        sendEvent(mapOf("event" to "sessionEstablished"))
                    } catch (e: Exception) {
                        sendEvent(
                            mapOf("event" to "connectionLost", "reason" to (e.message ?: "falha ao conectar")),
                        )
                    }
                }

                override fun onLost(network: Network) {
                    sendEvent(mapOf("event" to "connectionLost", "reason" to "rede perdida"))
                }

                override fun onUnavailable() {
                    sendEvent(
                        mapOf("event" to "connectionLost", "reason" to "caminho de dados indisponível"),
                    )
                }
            }
        networkCallback = callback
        try {
            connectivityManager.requestNetwork(request, callback)
        } catch (e: Exception) {
            sendEvent(mapOf("event" to "connectionLost", "reason" to (e.message ?: "falha ao requisitar rede")))
        }
    }

    private fun acceptIncoming(socket: ServerSocket) {
        Thread {
            try {
                val accepted = socket.accept()
                dataSocket = accepted
                readIncoming(accepted.getInputStream())
            } catch (e: Exception) {
                // `close()`/`closeAll()` fecha o `ServerSocket` de propósito para
                // interromper este `accept()` — exceção esperada nesse caso, não
                // um erro para reportar.
            }
        }.start()
    }

    private fun readIncoming(input: InputStream) {
        Thread {
            val buffer = ByteArray(65536)
            try {
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    sendEvent(
                        mapOf("event" to "dataReceived", "bytes" to buffer.copyOf(n)),
                    )
                }
            } catch (e: Exception) {
                // Conexão encerrada — `onLost`/`onUnavailable` já cobre o motivo
                // quando é a rede que caiu; aqui só paramos de ler.
            }
        }.start()
    }

    private fun send(bytes: ByteArray, result: MethodChannel.Result) {
        val socket = dataSocket
        if (socket == null) {
            result.error("not_connected", "Caminho de dados ainda não estabelecido", null)
            return
        }
        try {
            DataOutputStream(socket.getOutputStream()).write(bytes)
            result.success(null)
        } catch (e: Exception) {
            result.error("send_failed", e.message, null)
        }
    }

    private fun closeAll() {
        try {
            dataSocket?.close()
        } catch (e: Exception) {
        }
        dataSocket = null
        try {
            serverSocket?.close()
        } catch (e: Exception) {
        }
        serverSocket = null
        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        networkCallback?.let {
            try {
                connectivityManager?.unregisterNetworkCallback(it)
            } catch (e: Exception) {
            }
        }
        networkCallback = null
        discoverySession?.close()
        discoverySession = null
        awareSession?.close()
        awareSession = null
        peerHandle = null
        pendingPort = null
    }

    // ---- EventChannel ---------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
