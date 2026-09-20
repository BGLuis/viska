import CoreBluetooth
import Flutter

/// Canal de plataforma para anúncio BLE por UUID de serviço rotativo —
/// `docs/protocol.md` §9.1, Fase 6 F2. Espelha `BleAdvertiserPlugin.kt`
/// (mesmo nome de canal, mesmos três métodos), para que o lado Dart
/// (`ble_advertiser_channel.dart`) seja idêntico nas duas plataformas.
///
/// `CBPeripheralManager` só aceita `CBAdvertisementDataServiceUUIDsKey` —
/// não existe manufacturer data anunciável fora de perfis proprietários no
/// iOS, então a restrição da decisão 2.2 do relatório da Fase 6 (nunca
/// manufacturer data) já vem garantida pela própria API, não por disciplina
/// deste código.
///
/// Não verificado em hardware real: esta máquina é Linux, sem Xcode — só
/// escrito por leitura de API (Fase 6, §5 do relatório, e regra do
/// `CLAUDE.md` sobre ambiente de desenvolvimento).
class BleAdvertiser: NSObject, CBPeripheralManagerDelegate {
  private var peripheralManager: CBPeripheralManager?
  private var pendingServiceUuid: CBUUID?
  private var pendingResult: FlutterResult?

  static let channelName = "viska/ble_advertiser"

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = BleAdvertiser()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported())
    case "startAdvertising":
      guard let args = call.arguments as? [String: Any],
        let serviceUuid = args["serviceUuid"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "serviceUuid ausente", details: nil))
        return
      }
      startAdvertising(serviceUuid: serviceUuid, result: result)
    case "stopAdvertising":
      stopAdvertisingInternal()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isSupported() -> Bool {
    // `CBPeripheralManager` sempre existe no iOS moderno; se o rádio está
    // de fato ligado e autorizado só se sabe assincronamente, via
    // `peripheralManagerDidUpdateState` — aqui só confirmamos que a API
    // existe, mesma convenção do lado Android ("não é erro, só
    // indisponível").
    return true
  }

  private func startAdvertising(serviceUuid: String, result: @escaping FlutterResult) {
    stopAdvertisingInternal()
    guard let uuid = UUID(uuidString: serviceUuid) else {
      result(FlutterError(code: "bad_args", message: "serviceUuid inválido", details: nil))
      return
    }
    pendingServiceUuid = CBUUID(nsuuid: uuid)
    pendingResult = result
    // A publicidade em si só pode começar em `peripheralManagerDidUpdateState`,
    // quando o estado chegar a `.poweredOn` — não dá para anunciar antes disso.
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
  }

  private func stopAdvertisingInternal() {
    peripheralManager?.stopAdvertising()
    peripheralManager = nil
    pendingServiceUuid = nil
    pendingResult = nil
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard let serviceUuid = pendingServiceUuid else { return }

    switch peripheral.state {
    case .poweredOn:
      peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUuid]])
    case .unauthorized:
      pendingResult?(
        FlutterError(code: "permission_denied", message: "Sem permissão de Bluetooth", details: nil))
      pendingResult = nil
    case .unsupported:
      pendingResult?(
        FlutterError(code: "unsupported", message: "Aparelho não suporta BLE", details: nil))
      pendingResult = nil
    case .poweredOff, .resetting, .unknown:
      // Estado transitório — espera a próxima atualização em vez de
      // reportar erro cedo demais.
      break
    @unknown default:
      break
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      pendingResult?(
        FlutterError(code: "advertise_failed", message: error.localizedDescription, details: nil))
    } else {
      pendingResult?(nil)
    }
    pendingResult = nil
  }
}
