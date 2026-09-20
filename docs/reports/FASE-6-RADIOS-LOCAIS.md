# Fase 6 — descoberta e transporte por rádio local

| Campo | Valor |
|-------|-------|
| **Status** | ⚠️ Implementada (F0–F5), **não verificada em hardware** |
| **Cobertura** | 6 de 6 tarefas escritas e com testes automatizados onde é possível; nenhuma delas rodou em aparelho físico ainda |
| **Esforço realizado** | Todo o escopo completo (F0–F5) numa sessão — BLE/Wi-Fi Aware/MultipeerConnectivity escritos sem poder compilar (iOS) nem testar (nenhum dos três) nesta máquina |
| **Dependeu de** | Fase 3 — o `P2PTransportRouter` já existia e ganhou um segundo (e terceiro, e quarto) transporte sem mudar de contrato |
| **Atenção** | Item 5 do relatório original continua verdadeiro: **nada aqui foi validado com hardware real**. O que mudou é que agora há código para validar — antes não havia nenhum. |

---

## 1. Estado atual — evidências

**Atualizado após a implementação de F0–F5** (a versão original desta seção, que descrevia um
projeto com só a rotação de época pronta, está preservada por baixo, na íntegra, para referência
histórica).

### O que existe agora

- `rust/logic/src/discovery/beacon.rs` — deriva o `BeaconID` exatamente como `docs/protocol.md`
  §9.1 normatiza, reusando `K_sig` da sinalização. `rust/src/ffi/discovery.rs` expõe isso ao Dart
  (`discovery_beacons`, `match_discovered_beacon`, `my_device_id`).
- `rust/src/ffi/framing.rs` — `wire::framing` (antes só interno ao core Rust) agora tem ponte FFI,
  usada pelo socket TCP local e pelo Wi-Fi Aware.
- `lib/src/transport/lan/` — mDNS (`package:nsd`) + socket TCP, com preâmbulo de multiplexação de
  canal (`docs/protocol.md` §9.3).
- `lib/src/transport/selecting_p2p_transport.dart` + `transport_candidates.dart` —
  `P2PTransportRouter` agora escolhe entre LAN, Wi-Fi Aware/MultipeerConnectivity (conforme SO) e
  WebRTC, nessa ordem, sem ter mudado de contrato.
- `lib/src/discovery/` — `NearbyPresenceService` (BLE, só descoberta) +
  `ble/{ble_scanner,ble_advertiser,ble_advertiser_channel}.dart`.
- `lib/src/transport/wifi_aware/` e `lib/src/transport/multipeer/` — transportes de dados de
  verdade sobre Wi-Fi Aware (Android) e MultipeerConnectivity (iOS).
- `android/app/src/main/kotlin/app/viska/viska/{BleAdvertiserPlugin,WifiAwarePlugin}.kt` e
  `ios/Runner/{BleAdvertiser,MultipeerPlugin}.swift` — canais de plataforma nativos.
- Testes: `cargo test` (Rust) e `flutter test` cobrem tudo que não depende de rádio real — a lógica
  de derivação, roteamento, enquadramento e multiplexação. Nenhum teste toca `MethodChannel`/
  `EventChannel` de verdade (dublês manuais em todos os casos, convenção do projeto).

### O que continua não existindo

- Nenhuma validação em hardware — nem um único teste manual com dois aparelhos.
- `lan_advertising_policy.dart` tem uma política real (`ActiveContactsAdvertisingPolicy`), mas
  nenhuma tela liga isso a "conversa aberta agora" — o gancho de UI não existe.
- Suporte a mais de um contato usando Wi-Fi Aware ou MultipeerConnectivity **ao mesmo tempo**: os
  dois plugins nativos só acompanham uma sessão por vez (ver §6, risco novo).

<details>
<summary>Versão original desta seção (antes da implementação) — histórico</summary>

A infraestrutura de rotação, que serve tanto ao beacon quanto à sinalização:

```rust
// rust/src/util/time.rs — janela de três épocas, para tolerar desvio de relógio
pub fn epoch_window() -> [u64; 3] {
    let now = current_epoch();
    [now.saturating_sub(1), now, now + 1]
}
```

O contexto `viska-beacon-v1` está declarado em `crypto/kdf.rs`, e nenhuma função o usa ainda.

```bash
grep -n "blue_plus\|nsd\|bonsoir\|nearby" pubspec.yaml
# → 0 resultados
```

Nenhum canal de plataforma em `android/` ou `ios/` além do esqueleto do `flutter create`.

</details>

---

## 2. As cinco decisões de design

### 2.1 A matriz de transporte não é uma escolha, é uma restrição das plataformas

| Cenário | Caminho | Por quê |
|---|---|---|
| Mesma LAN, qualquer SO | mDNS/DNS-SD + socket TCP | Único caminho que funciona Android ↔ iOS e não depende de Google Play Services |
| Android ↔ Android sem rede | Wi-Fi Aware (API 26+) | Alta banda, sem GMS |
| iOS ↔ iOS sem rede | MultipeerConnectivity | Único equivalente na plataforma |
| Android ↔ iOS sem rede nenhuma | BLE L2CAP, ou um vira ponto de acesso | ~1 Mbps; não existe nada melhor |

A última linha é a consequência inescapável de D9: Wi-Fi Direct não existe no iOS, e Nearby
Connections não conversa com MultipeerConnectivity. Qualquer plano que prometa transferência rápida
entre Android e iOS sem infraestrutura está errado.

### 2.2 O BeaconID vai no UUID de serviço, nunca em manufacturer data

Spec §9.1. O iOS em segundo plano **não anuncia** manufacturer data e move os UUIDs de serviço para
a *overflow area*, onde só são achados por um scanner que procure exatamente aquele UUID. Como
segundo plano é o caso de uso principal — o app precisa perceber o contato por perto sem estar
aberto — o identificador rotativo tem que ser o próprio UUID de 128 bits.

### 2.3 A janela de três épocas é obrigatória dos dois lados

O anunciante publica a época corrente; o scanner procura `e-1`, `e` e `e+1`. Sem isso, dois
aparelhos com relógios poucos minutos dessincronizados não se acham perto da virada da hora, e o
sintoma é "às vezes não encontra", que é o pior tipo de defeito para diagnosticar.

### 2.4 Migração de transporte não pode derrubar a sessão

A sessão criptográfica vive acima do transporte por construção — o ratchet não sabe por onde os
bytes chegaram. Migrar de LAN para WebRTC no meio de uma transferência é, portanto, possível; mas o
particionamento em source blocks muda com o tamanho do símbolo (D5), então o bloco em curso
reinicia. Ver Fase 4, armadilha correspondente.

### 2.5 O que não fazer

**Não usar `nearby_connections`.** Depende do Google Play Services e contradiz a premissa de
ausência de infraestrutura proprietária (§1.1). A decisão já foi tomada e registrada em D9.

---

## 3. Plano de implementação

| Fase | Conteúdo | Status |
|---|---|---|
| **F0** | Derivação do BeaconID e do nome de instância mDNS por época — `rust/logic/src/discovery/` (não `rust/src/discovery/` como este relatório previa: a derivação é lógica de protocolo, pertence ao crate `viska_proto`, com FFI fino em `rust/src/ffi/discovery.rs`, mesma separação de `signaling/`) | ✅ Implementado e testado (`cargo test`) |
| **F1** | mDNS/DNS-SD com `nsd` (decisão tomada: não `bonsoir`), socket TCP com o enquadramento de `wire/framing.rs` (agora também exposto via FFI, `rust/src/ffi/framing.rs`) | ✅ Implementado e testado (`flutter test`, inclusive round-trip real por socket TCP em loopback) |
| **F2** | BLE: anúncio e varredura por UUID rotativo, com canal de plataforma próprio — `flutter_blue_plus` só cobre o scanner | ✅ Implementado (Dart testado; Kotlin/Swift não verificados — ver §6) |
| **F3** | Integração ao `P2PTransportRouter`: seleção e *failover* (`SelectingP2PTransport`) | ✅ Implementado e testado — migração ativa em transferência continua **não** implementada (ver 2.4) |
| **F4** | Wi-Fi Aware no Android, via canal de plataforma | ✅ Implementado (Dart testado com dublê do canal; Kotlin não verificado — ver §6) |
| **F5** | MultipeerConnectivity no iOS, via canal de plataforma | ✅ Implementado (Dart testado com dublê do canal; Swift não compila nesta máquina — ver §6) |

O plano original estimava 10–14 dias-dev para o escopo completo; foi todo escrito numa única sessão,
o que é possível mas não reduz o risco descrito no plano original — só adia a descoberta de defeitos
para quando alguém rodar isso em hardware pela primeira vez (§6).

---

## 4. Armadilhas

| Armadilha | Mitigação | Status |
|---|---|---|
| Android exige `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` e, em versões antigas, permissão de localização | Pedir no momento certo e explicar por quê; permissão de localização para BLE é o pedido que mais assusta usuário. | Permissões declaradas em `AndroidManifest.xml` (`neverForLocation` no `BLUETOOTH_SCAN` das versões novas). **Pedir na hora certa** continua sendo trabalho de UI, não feito — hoje é responsabilidade de quem chamar `NearbyPresenceService`/`LanTransport`. |
| iOS exige permissão de rede local para mDNS, com diálogo próprio | `NSLocalNetworkUsageDescription` e `NSBonjourServices` no `Info.plist`; sem os dois, a descoberta falha em silêncio. | Feito, junto com as chaves equivalentes de BLE (`NSBluetoothAlwaysUsageDescription`) e MultipeerConnectivity (`_viska-p2p._tcp`/`_udp` em `NSBonjourServices`). |
| Aleatorização de MAC precisa estar ativa, ou o beacon rotativo é inútil | O endereço físico anula toda a rotação se for estável. Verificar em captura de rádio, não na documentação. | Fora do controle do app (é o SO quem aleatoriza); continua **não verificado** — precisa de captura de rádio real. |
| Anúncio BLE em segundo plano no iOS é severamente limitado | Decisão 2.2. Ainda assim, validar em aparelho real com o app fechado — é o cenário que a spec pressupõe. | Implementado conforme a API (`CBPeripheralManager`); comportamento real em segundo plano **não verificado**. |
| `extract_frame` devolve `Err` sem limpar o buffer | O transporte TCP **tem** que derrubar a conexão nesse caso; tentar de novo reencontra o mesmo quadro inválido para sempre. | Feito e testado em `LanTransport`/`WifiAwareTransport` — os dois derrubam a conexão/caminho de dados assim que `extract_frame` rejeita um quadro, nunca retentam sobre o mesmo buffer. |

---

## 5. Verificação

**Automatizável no host (`cargo test`) — feito, 274 testes passando no workspace:**

- [x] O BeaconID muda entre épocas e é idêntico nos dois lados dentro da mesma — guarda §9.1
      (`rust/logic/src/discovery/beacon.rs`).
- [x] Um par sem o segredo compartilhado não reconhece o beacon — é o que faz a rotação valer
      (`quem_nao_compartilha_k_sig_produz_beacon_diferente`).
- [x] `frame`/`extract_frame` expostos via FFI fazem round-trip e rejeitam comprimento absurdo sem
      alocar (`rust/src/ffi/framing.rs`).

**Automatizável no host (`flutter test`) — feito, suíte inteira (18 arquivos, ~120 testes)
passando com `-j 1`** (a concorrência padrão do `flutter test` mostrou-se instável *nesta sandbox*,
derrubando arquivos ao acaso sem relação com o código — rodar serial, `flutter test -j 1`, se isso
se repetir):

- [x] O router escolhe o transporte local quando há beacon válido, e cai para o remoto quando não
      há (`selecting_p2p_transport_test.dart`, com dublês — não com rádio real).
- [x] Preâmbulo de multiplexação TCP roteia `control`/`file` para conexões independentes, e
      sobrevive a um preâmbulo+quadro chegando no mesmo pacote (`lan_listener_test.dart`).
- [x] Conexão é derrubada quando `extract_frame` rejeita um quadro, em `LanTransport` e
      `WifiAwareTransport`.
- [x] BLE encontra o contato certo quando o beacon bate, e ignora UUID desconhecido
      (`nearby_presence_service_test.dart`, com dublê do scanner/advertiser).
- [x] Wi-Fi Aware/MultipeerConnectivity: papel ativo assina/procura, papel passivo publica/anuncia,
      dados roteados pelo marcador de canal — tudo com dublê do canal de plataforma, nunca com
      `MethodChannel`/`EventChannel` reais.

**Só em hardware real, dois aparelhos (continua não verificado — nada mudou aqui):**

- [ ] Descoberta por BLE com o app em segundo plano, em Android e em iOS.
- [ ] Transferência iniciada na LAN e migrada para WebRTC ao sair do alcance, sem perder a sessão.
- [ ] Android ↔ iOS na mesma Wi-Fi, que é o caminho universal e o mais importante dos quatro.
- [ ] Captura de rádio confirmando que o MAC anunciado é aleatorizado.
- [ ] Wi-Fi Aware ponta a ponta em pelo menos dois fabricantes Android diferentes.
- [ ] MultipeerConnectivity ponta a ponta (exige Mac + dois iPhones/iPads — nem compila aqui).
- [ ] O código Kotlin/Swift sequer **compila** fora desta revisão de texto — nenhum dos dois
      passou por `./gradlew build` nem `xcodebuild` nesta sessão.

---

## 6. Riscos

1. **O código nativo (Kotlin/Swift) não foi compilado, nem por um único build, nesta sessão.** Foi
   escrito por leitura da API pública do Android/iOS, revisado com cuidado, mas
   `BleAdvertiserPlugin.kt`, `WifiAwarePlugin.kt`, `BleAdvertiser.swift` e `MultipeerPlugin.swift`
   podem conter erros de compilação triviais (nome de método errado, import faltando) que só um
   `./gradlew build` ou `xcodebuild` real revelam. **Antes de qualquer teste em hardware, rodar os
   dois builds.**

2. **Limitação nova, introduzida por esta implementação: só uma sessão Wi-Fi Aware e uma sessão
   MultipeerConnectivity por vez, no processo inteiro.** `WifiAwarePlugin.kt` e `MultipeerPlugin.swift`
   só acompanham um `PeerHandle`/uma `MCSession` de cada vez — se o `P2PTransportRouter` tentar usar
   Wi-Fi Aware para dois contatos ao mesmo tempo, o segundo pisa no estado do primeiro. Não é uma
   limitação da API do Android/iOS (que suporta múltiplas sessões), é uma simplificação deste
   código. Registrado aqui para não ser "descoberto" em produção como um bug misterioso.

3. **A negociação de caminho de dados do Wi-Fi Aware (`WifiAwarePlugin.kt`) é a peça de maior risco
   de estar sutilmente errada.** Depende de uma troca de mensagens (`sendMessage`) só para o
   publicador aprender o `PeerHandle` do assinante antes de pedir a rede — um padrão real da API,
   mas com bastante superfície para um detalhe (timing, formato do `serviceSpecificInfo`) estar
   errado sem que nenhum teste local pegue, já que nenhum teste local pode.

4. **O comportamento de BLE em segundo plano continua o item mais provável de exigir retrabalho.**
   As restrições do iOS são conhecidas e já influenciaram o desenho, mas o comportamento real só
   aparece em aparelho, com o app fechado, ao longo de horas.

5. **Wi-Fi Aware tem cobertura irregular entre fabricantes Android.** Estar na API 26+ não garante
   que o aparelho implemente; `WifiAwareTransport.isLikelyReachable` degrada para os próximos
   candidatos (`SelectingP2PTransport`) sem apresentar erro ao usuário — mitigado no desenho, não
   verificado em hardware de fabricante nenhum.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/logic/src/discovery/{mod,beacon}.rs` | **novo** — BeaconID e nome de instância por época (F0) |
| `rust/src/ffi/{discovery,framing}.rs` | **novo** — ponte FFI do beacon e do `wire::framing` |
| `pubspec.yaml` | **modificado** — `nsd`, `flutter_blue_plus`, `fake_async` (dev) adicionados |
| `lib/src/discovery/{beacon_id,nearby_presence_service}.dart`, `discovery/ble/*.dart` | **novo** — F0/F2 |
| `lib/src/transport/lan/*.dart` | **novo** — F1 (`lan_discovery`, `nsd_lan_discovery`, `lan_listener`, `lan_transport`, `lan_advertising_policy`) |
| `lib/src/transport/selecting_p2p_transport.dart`, `transport_candidates.dart` | **novo** — F3 |
| `lib/src/transport/p2p_transport_router.dart` | **modificado** — fábrica padrão usa `SelectingP2PTransport` |
| `lib/src/transport/wifi_aware/*.dart` | **novo** — F4 |
| `lib/src/transport/multipeer/*.dart` | **novo** — F5 |
| `android/app/src/main/kotlin/app/viska/viska/{BleAdvertiserPlugin,WifiAwarePlugin,MainActivity}.kt` | **novo/modificado** — canais de BLE e Wi-Fi Aware |
| `ios/Runner/{BleAdvertiser,MultipeerPlugin,AppDelegate}.swift` | **novo/modificado** — canais de BLE e MultipeerConnectivity |
| `android/.../AndroidManifest.xml` | **modificado** — permissões de BLE e Wi-Fi Aware |
| `ios/Runner/Info.plist` | **modificado** — `NSLocalNetworkUsageDescription`, `NSBonjourServices` (mDNS e Multipeer), `NSBluetoothAlwaysUsageDescription` |
| `docs/protocol.md` §9 | **modificado** — §9.3–9.6 novas (preâmbulo TCP, Wi-Fi Aware, MultipeerConnectivity, lacuna do BLE) |
| `test/discovery/`, `test/transport/{lan,wifi_aware,multipeer}/`, `test/transport/selecting_p2p_transport_test.dart` | **novo** — toda a cobertura automatizada desta fase |

---

> **F0–F5 implementados nesta sessão.** Tudo que é automatizável (`cargo test`, `flutter test`) foi
> escrito e está passando — 274 testes Rust, ~120 testes Dart. O que a seção 5 já dizia que seria
> impossível de automatizar continua impossível: quatro dos itens de verificação exigem hardware
> real, que não está disponível nesta máquina, e o código nativo Kotlin/Swift nunca passou por um
> build de verdade (risco 1, §6). Tratar esta fase como "pronta para produção" seria um erro — ela
> está pronta para a próxima etapa, que é compilar e testar em aparelhos físicos.
