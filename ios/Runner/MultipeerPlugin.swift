import Flutter
import MultipeerConnectivity

/// Canal de plataforma para MultipeerConnectivity — `docs/protocol.md` §9,
/// Fase 6 F5.
///
/// `serviceType` é fixo (`"viska-p2p"`, decisão de implementação flagged
/// #5 do plano da Fase 6): a API do Apple exige uma string curta
/// `[a-z0-9-]` de 1–15 caracteres, sem pontos — não aceita `_viska._tcp`
/// literal. A identidade do par continua vindo do beacon (mesma convenção
/// de hex do nome de instância mDNS, `docs/protocol.md` §9.2), carregado
/// dentro do `discoveryInfo` do anúncio, não no `serviceType`.
///
/// `MCPeerID.displayName` é um identificador visível a qualquer aparelho
/// que esteja varrendo por perto, antes mesmo de qualquer convite — por
/// isso é um nome aleatório por sessão, nunca derivado da identidade real
/// (mesmo raciocínio da aleatorização de MAC do BLE, §9.1: nada de
/// identidade estável exposto sem a chave compartilhada).
///
/// Como `MCSession.send` já entrega mensagens delimitadas (não é um fluxo
/// de bytes cru como um socket TCP), não passa por `wire::framing` — só um
/// byte de marcador de canal (`control`/`file`) antes de cada mensagem,
/// mesma convenção de `WifiAwarePlugin.kt`/`wifi_aware_transport.dart`.
///
/// Não verificado em hardware real: esta máquina é Linux, sem Xcode — só
/// escrito por leitura de API. Ver Fase 6, §5/§6 do relatório, e
/// `CLAUDE.md` (ambiente de desenvolvimento).
class MultipeerPlugin: NSObject, FlutterStreamHandler, MCSessionDelegate,
  MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate
{
  private static let serviceType = "viska-p2p"

  private let myPeerId = MCPeerID(displayName: UUID().uuidString)
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var expectedBeaconHex: String?
  private var connectedPeer: MCPeerID?
  private var eventSink: FlutterEventSink?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = MultipeerPlugin()
    let methodChannel = FlutterMethodChannel(name: "viska/multipeer", binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    let eventChannel = FlutterEventChannel(name: "viska/multipeer/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(instance)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "advertise":
      guard let args = call.arguments as? [String: Any],
        let beaconHex = args["beaconHex"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "beaconHex ausente", details: nil))
        return
      }
      advertise(beaconHex: beaconHex)
      result(nil)
    case "browse":
      guard let args = call.arguments as? [String: Any],
        let beaconHex = args["beaconHex"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "beaconHex ausente", details: nil))
        return
      }
      browse(expectedBeaconHex: beaconHex)
      result(nil)
    case "send":
      guard let args = call.arguments as? [String: Any],
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "bytes ausente", details: nil))
        return
      }
      send(data: bytes.data, result: result)
    case "close":
      closeAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureSession() -> MCSession {
    if let existing = session { return existing }
    let newSession = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
    newSession.delegate = self
    session = newSession
    return newSession
  }

  // ---- Anunciante (passivo) ----------------------------------------------

  private func advertise(beaconHex: String) {
    stopAdvertisingAndBrowsing()
    let session = ensureSession()
    _ = session
    let newAdvertiser = MCNearbyServiceAdvertiser(
      peer: myPeerId,
      discoveryInfo: ["beacon": beaconHex],
      serviceType: Self.serviceType
    )
    newAdvertiser.delegate = self
    advertiser = newAdvertiser
    newAdvertiser.startAdvertisingPeer()
  }

  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didReceiveInvitationFromPeer peerID: MCPeerID,
    withContext context: Data?,
    invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    invitationHandler(true, ensureSession())
  }

  // ---- Navegador (ativo) --------------------------------------------------

  private func browse(expectedBeaconHex: String) {
    stopAdvertisingAndBrowsing()
    self.expectedBeaconHex = expectedBeaconHex
    let newBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: Self.serviceType)
    newBrowser.delegate = self
    browser = newBrowser
    newBrowser.startBrowsingForPeers()
  }

  func browser(
    _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
    withDiscoveryInfo info: [String: String]?
  ) {
    guard let beacon = info?["beacon"], beacon == expectedBeaconHex else { return }
    eventSink?(["event": "serviceDiscovered"])
    browser.invitePeer(peerID, to: ensureSession(), withContext: nil, timeout: 30)
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    // Sem ação — a perda de um peer ainda não convidado não é um evento que
    // `MultipeerTransport` do lado Dart precise tratar.
  }

  func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    eventSink?(["event": "connectionLost", "reason": error.localizedDescription])
  }

  // ---- MCSessionDelegate --------------------------------------------------

  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    switch state {
    case .connected:
      connectedPeer = peerID
      eventSink?(["event": "sessionEstablished"])
    case .notConnected:
      if connectedPeer == peerID {
        connectedPeer = nil
        eventSink?(["event": "connectionLost", "reason": "sessão desconectada"])
      }
    case .connecting:
      break
    @unknown default:
      break
    }
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    eventSink?(["event": "dataReceived", "bytes": FlutterStandardTypedData(bytes: data)])
  }

  func session(
    _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
    fromPeer peerID: MCPeerID
  ) {
    // Não usado — só o canal de dados discreto (`send`/`didReceive data:`)
    // é usado, nunca `InputStream` bruto.
  }

  func session(
    _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, with progress: Progress
  ) {}

  func session(
    _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
  ) {}

  // ---- Envio / encerramento ------------------------------------------------

  private func send(data: Data, result: @escaping FlutterResult) {
    guard let session = session, let peer = connectedPeer else {
      result(FlutterError(code: "not_connected", message: "Sessão ainda não estabelecida", details: nil))
      return
    }
    do {
      try session.send(data, toPeers: [peer], with: .reliable)
      result(nil)
    } catch {
      result(FlutterError(code: "send_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func stopAdvertisingAndBrowsing() {
    advertiser?.stopAdvertisingPeer()
    advertiser = nil
    browser?.stopBrowsingForPeers()
    browser = nil
  }

  private func closeAll() {
    stopAdvertisingAndBrowsing()
    session?.disconnect()
    session = nil
    connectedPeer = nil
    expectedBeaconHex = nil
  }

  // ---- FlutterStreamHandler -----------------------------------------------

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
