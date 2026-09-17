# Fase 6 — descoberta e transporte por rádio local

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada |
| **Cobertura** | ~5 % (0 de 6 tarefas) — só a rotação de época existe |
| **Esforço** | 10–14 dias-dev no escopo completo; 4–5 d no mínimo viável [modelado] |
| **Depende de** | Fase 3 — o `P2PTransportRouter` precisa existir antes de ganhar um segundo transporte |
| **Atenção** | É a fase que **não pode** ser validada sem hardware; nenhum emulador reproduz BLE ou Wi-Fi Aware |

---

## 1. Estado atual — evidências

### O que existe

A infraestrutura de rotação, que serve tanto ao beacon quanto à sinalização:

```rust
// rust/src/util/time.rs — janela de três épocas, para tolerar desvio de relógio
pub fn epoch_window() -> [u64; 3] {
    let now = current_epoch();
    [now.saturating_sub(1), now, now + 1]
}
```

O contexto `viska-beacon-v1` está declarado em `crypto/kdf.rs`, e nenhuma função o usa ainda.

### O que não existe

```bash
grep -n "blue_plus\|nsd\|bonsoir\|nearby" pubspec.yaml
# → 0 resultados
```

Nenhum canal de plataforma em `android/` ou `ios/` além do esqueleto do `flutter create`.

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

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | `rust/src/discovery/`: derivação do BeaconID e do nome de instância mDNS por época | 0,5 d |
| **F1** | mDNS/DNS-SD com `nsd` ou `bonsoir`, socket TCP com o enquadramento de `wire/framing.rs` | 2–3 d |
| **F2** | BLE: anúncio e varredura por UUID rotativo, com canal de plataforma próprio — `flutter_blue_plus` não cobre anúncio em todos os casos | 3–4 d |
| **F3** | Integração ao `P2PTransportRouter`: seleção, *failover* e migração | 1,5–2 d |
| **F4** | Wi-Fi Aware no Android, via canal de plataforma | 2 d |
| **F5** | MultipeerConnectivity no iOS, via canal de plataforma | 2–3 d |

**Mínimo viável** (dois aparelhos na mesma Wi-Fi se acham e transferem): F0 + F1 + F3 ≈ 4–5,5 d.
**Escopo completo:** F0–F5 ≈ 11–14,5 d.

Ordem importa: F1 antes de F2 entrega o caminho de alta banda primeiro, e o BLE passa a ser só
descoberta — que é o papel dele de qualquer forma.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| Android exige `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` e, em versões antigas, permissão de localização | Pedir no momento certo e explicar por quê; permissão de localização para BLE é o pedido que mais assusta usuário. |
| iOS exige permissão de rede local para mDNS, com diálogo próprio | `NSLocalNetworkUsageDescription` e `NSBonjourServices` no `Info.plist`; sem os dois, a descoberta falha em silêncio. |
| Aleatorização de MAC precisa estar ativa, ou o beacon rotativo é inútil | O endereço físico anula toda a rotação se for estável. Verificar em captura de rádio, não na documentação. |
| Anúncio BLE em segundo plano no iOS é severamente limitado | Decisão 2.2. Ainda assim, validar em aparelho real com o app fechado — é o cenário que a spec pressupõe. |
| `extract_frame` devolve `Err` sem limpar o buffer | O transporte TCP **tem** que derrubar a conexão nesse caso; tentar de novo reencontra o mesmo quadro inválido para sempre. |

---

## 5. Verificação

**Automatizável no host (`cargo test`):**

- [ ] O BeaconID muda entre épocas e é idêntico nos dois lados dentro da mesma — guarda §9.1.
- [ ] Um par sem o segredo compartilhado não reconhece o beacon — é o que faz a rotação valer.

**Automatizável no host (`flutter test`):**

- [ ] O router escolhe o transporte local quando há beacon válido, e cai para o remoto quando não há.

**Só em hardware real, dois aparelhos (não verificado até rodar):**

- [ ] Descoberta por BLE com o app em segundo plano, em Android e em iOS.
- [ ] Transferência iniciada na LAN e migrada para WebRTC ao sair do alcance, sem perder a sessão.
- [ ] Android ↔ iOS na mesma Wi-Fi, que é o caminho universal e o mais importante dos quatro.
- [ ] Captura de rádio confirmando que o MAC anunciado é aleatorizado.

---

## 6. Riscos

1. **Esta é a fase de maior risco de cronograma do projeto.** Quatro caminhos de transporte, dois
   deles em código nativo por plataforma, nenhum verificável sem hardware — e um deles (iOS) sem
   sequer poder ser compilado nesta máquina.

2. **O comportamento de BLE em segundo plano é o item mais provável de exigir retrabalho.** As
   restrições do iOS são conhecidas e já influenciaram o desenho, mas o comportamento real só
   aparece em aparelho, com o app fechado, ao longo de horas.

3. **Wi-Fi Aware tem cobertura irregular entre fabricantes Android.** Estar na API 26+ não garante
   que o aparelho implemente; o caminho precisa degradar para mDNS sem apresentar erro ao usuário.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/src/discovery/` | **novo** — BeaconID e nome de instância por época |
| `pubspec.yaml` | `flutter_blue_plus`, `nsd` ou `bonsoir`, `permission_handler` |
| `lib/src/transport/{lan_transport,ble_beacon}.dart` | **novo** |
| `android/app/src/main/kotlin/` | **novo** — canal de Wi-Fi Aware e anúncio BLE |
| `ios/Runner/` | **novo** — canal de MultipeerConnectivity |
| `AndroidManifest.xml` · `Info.plist` | permissões de BLE, rede local e Bonjour |

---

> Nenhum item deste relatório foi executado. Quatro dos sete itens de verificação da seção 5 são
> impossíveis de automatizar e três deles exigem um segundo aparelho físico, que não está disponível
> nesta máquina.
