# Viska Wire Protocol v1

Especificação normativa do protocolo. Toda implementação (Rust core, testes, futuras portas)
deve seguir este documento. Divergências entre código e este arquivo são bug no código.

Baseado na especificação de arquitetura original, com os desvios D1–D13 documentados em
`docs/deviations.md` já incorporados.

---

## 1. Primitivas

| Função | Algoritmo | Parâmetros |
|---|---|---|
| Assinatura de identidade | Ed25519 (RFC 8032) | chave 32 B, assinatura 64 B |
| Acordo de chaves clássico | X25519 (RFC 7748) | chave 32 B, segredo 32 B |
| KEM pós-quântico | ML-KEM-768 (FIPS 203) | ek 1184 B, ct 1088 B, ss 32 B |
| AEAD de mensagem | ChaCha20-Poly1305 (RFC 8439) | chave 32 B, nonce 12 B, tag 16 B |
| AEAD de arquivo e sinalização | XChaCha20-Poly1305 | chave 32 B, nonce 24 B, tag 16 B |
| Hash / KDF / MAC | BLAKE3 | saída 32 B por padrão |

Toda derivação de chave usa `BLAKE3::derive_key(context, key_material)` com um contexto textual
único e literal. Contextos em uso:

```
viska-qr-sig-v1            assinatura do payload do QR
viska-safety-number-v1     safety number exibido ao usuário
viska-handshake-v1         raiz da sessão a partir do material do AKE
viska-root-chain-v1        passo da cadeia raiz do ratchet
viska-send-chain-v1        passo da cadeia simétrica (envio e recepção — ver §5.3)
viska-msg-key-v1           chave de mensagem a partir da chave de cadeia
viska-rekem-v1             mistura do re-encapsulamento ML-KEM periódico
viska-signaling-v1         chave de ofuscação/cifra do canal de sinalização
viska-beacon-v1            derivação do BeaconID BLE rotativo
viska-file-key-v1          chave por transferência de arquivo
viska-staging-v1           chave de cifragem em repouso do arquivo .staging
viska-db-key-v1            chave do banco SQLCipher
```

Aleatoriedade: exclusivamente `getrandom` (CSPRNG do sistema operacional). Nenhum PRNG de
aplicação é usado para material de chave, nonce, padding ou jitter de tráfego.

---

## 2. Identidade

Uma identidade local é um triplo persistente:

```
IK_sig   : par Ed25519   — identidade de longo prazo, assina apenas o payload do QR
IK_dh    : par X25519    — identidade de longo prazo, autentica o handshake (D1)
device_id: 16 B aleatórios — identificador opaco, sem relação com hardware
```

`device_id` é gerado por CSPRNG e nunca derivado de IMEI, Android ID, MAC ou qualquer
identificador de hardware.

---

## 3. Pareamento óptico (QR Code)

### 3.1 Payload — 145 bytes, binário puro

```
offset  tam  campo
0       1    version        = 0x01
1       16   device_id
17      32   IK_sig.public  (Ed25519)
49      32   IK_dh.public   (X25519)
81      64   signature      = Ed25519(IK_sig.secret, derive_key("viska-qr-sig-v1", bytes[0..81]))
```

O QR é gerado em modo binário (byte mode). 145 B cabem em uma matriz Versão 7 com correção de
erro M, que é lida com folga por câmeras de celular medianas.

A assinatura é prova de posse da chave privada e integridade dos bytes lidos. Ela **não** é o que
impede MitM — isso vem do canal óptico presencial. É por isso que ela pode existir sem prejudicar
a deniabilidade da conversa (D1): assina uma chave pública, nunca conteúdo de mensagem.

### 3.2 Verificação no scan

1. `version == 0x01`, senão rejeita.
2. Verifica `signature` contra `IK_sig.public` do próprio payload.
3. Rejeita se `IK_sig.public` ou `IK_dh.public` forem iguais aos da identidade local (auto-pareamento).
4. Rejeita `IK_dh.public` de baixa ordem (todos os pontos de ordem < 8 da Curve25519).
5. Persiste o contato no banco cifrado.

### 3.3 Safety number — 60 bits (D3)

```
a  = BLAKE3(IK_sig_A ‖ IK_dh_A)
b  = BLAKE3(IK_sig_B ‖ IK_dh_B)
lo, hi = (a, b) ordenados lexicograficamente
sn = derive_key("viska-safety-number-v1", lo ‖ hi)
```

Onde `sn` é uma saída XOF de 60 bytes. Exibido como 12 grupos de 5 dígitos decimais:

```
sn = BLAKE3::derive_key("viska-safety-number-v1", lo ‖ hi).finalize_xof() -> 60 bytes
grupo_i = u40_be(sn[i*5 .. i*5+5]) % 100000        para i em 0..12
```

Entropia efetiva do valor exibido ≈ 12 × log2(100000) ≈ 199 bits, muito acima dos 60 bits mínimos
e dos ~20 bits do desenho original.

Também é oferecida uma representação em 6 palavras de uma lista de 2048 (66 bits) para leitura
em voz alta por canal de áudio confiável.

---

## 4. Handshake: AKE híbrido deniável (D1)

Sem assinaturas. A autenticação vem do fato de que `IK_dh` de cada par já foi obtida
presencialmente pelo QR. Estrutura PQXDH: X3DH + ML-KEM-768.

O iniciador é o par cuja `IK_dh.public` for lexicograficamente menor. Isso resolve handshakes
simultâneos sem round-trip extra.

### 4.1 Mensagem 1 — INIT (iniciador I → respondedor R)

Conteúdo em claro no canal (ainda não há sessão):

```
offset  tam    campo
0       1      version   = 0x01
1       1      msg_type  = 0x01 (INIT)
2       32     EK_I      chave pública X25519 efêmera do iniciador
34      1184   KEM_ek_I  chave pública de encapsulamento ML-KEM-768 do iniciador
                total: 1218 B
```

### 4.2 Mensagem 2 — RESP (R → I)

```
offset  tam    campo
0       1      version   = 0x01
1       1      msg_type  = 0x02 (RESP)
2       32     EK_R      chave pública X25519 efêmera do respondedor
34      1088   KEM_ct    ciphertext ML-KEM-768 encapsulado contra KEM_ek_I
                total: 1122 B
```

### 4.3 Derivação

Ambos os lados computam, com os papéis fixos por iniciador/respondedor:

```
DH1 = X25519(IK_dh_I , EK_R)      autentica I para R
DH2 = X25519(EK_I    , IK_dh_R)   autentica R para I
DH3 = X25519(EK_I    , EK_R)      forward secrecy
SS_KEM = ML-KEM-768 encaps/decaps

transcript = version ‖ IK_dh_I ‖ IK_dh_R ‖ EK_I ‖ EK_R ‖ KEM_ek_I ‖ KEM_ct

K_root_0 = derive_key("viska-handshake-v1", DH1 ‖ DH2 ‖ DH3 ‖ SS_KEM ‖ transcript)
```

Se qualquer DH produzir o ponto all-zero (contribuição de ordem baixa), o handshake aborta.

Por que isso é deniável: todo o material de autenticação é um segredo compartilhado entre os dois
pares. R consegue forjar sozinho um transcript completo e convincente de uma conversa com I, então
nenhum transcript prova nada a um terceiro.

### 4.4 Confirmação

A primeira mensagem de aplicação já serve de confirmação de chave: se o AEAD abrir, ambos
derivaram a mesma raiz. Não há pacote de confirmação dedicado (economiza um round-trip e evita
um oráculo).

---

## 5. Ratchet (D2)

Double Ratchet no estilo Signal, com BLAKE3 no lugar de HKDF-SHA256 e um ratchet KEM adicional.

### 5.1 Estado por sessão

```
RK            32 B  chave raiz
CKs, CKr      32 B  chaves de cadeia de envio e recepção (opcionais)
DHs           par X25519 efêmero local do ratchet
DHr           32 B  chave pública X25519 do ratchet remoto
Ns, Nr        u32   contadores de mensagem nas cadeias atuais
PN            u32   número de mensagens da cadeia de envio anterior
skipped       mapa (DHr, N) -> chave de mensagem, para entrega fora de ordem
KEM_sk, KEM_pk par ML-KEM-768 local para o próximo re-KEM
msgs_since_rekem, last_rekem_at
```

### 5.2 Passo DH

Ao receber um cabeçalho com `DHr` novo:

```
RK, CKr = kdf_rk(RK, X25519(DHs.secret, DHr_novo))
PN = Ns; Ns = 0; Nr = 0
DHs = nova chave X25519
RK, CKs = kdf_rk(RK, X25519(DHs.secret, DHr_novo))

kdf_rk(rk, dh) = { out = derive_key("viska-root-chain-v1", rk ‖ dh) em XOF de 64 B;
                   (out[0..32], out[32..64]) }
```

### 5.3 Passo simétrico

```
MK  = derive_key("viska-msg-key-v1",   CK ‖ 0x01)
CK' = derive_key("viska-send-chain-v1", CK ‖ 0x02)
```

> **Contexto único, de propósito.** Uma versão anterior desta especificação mandava avançar `CKs`
> com `viska-send-chain-v1` e `CKr` com `viska-recv-chain-v1`. Isso está errado e quebra o
> protocolo na primeira mensagem: a cadeia de **envio** de um par e a cadeia de **recepção** do
> outro são o mesmo segredo, evoluindo em paralelo nos dois aparelhos. Separação de domínio existe
> para materiais de chave diferentes, não para o mesmo valor visto de dois lados. O contexto
> `viska-recv-chain-v1` foi removido de `crypto/kdf.rs` para que ninguém volte a usá-lo.

`MK` é usada exatamente uma vez e zerada em seguida.

### 5.4 Ratchet KEM (re-encapsulamento periódico)

Gatilho: `msgs_since_rekem >= 256` **ou** `now - last_rekem_at >= 24 h`, o que vier primeiro.

O par que dispara inclui no cabeçalho cifrado um `KEM_ek` novo. A contraparte encapsula contra ele
e devolve o `KEM_ct` no cabeçalho cifrado da sua próxima mensagem. Ao completar, ambos fazem:

```
RK = derive_key("viska-rekem-v1", RK ‖ SS_KEM_novo)
```

Isso garante que a recuperação pós-comprometimento (PCS) seja pós-quântica, e não apenas clássica.
O tráfego extra é de 1184 B + 1088 B a cada 256 mensagens, amortizado em ~9 B por mensagem.

**A posição da dobra é normativa.** As duas dobras não comutam com o passo DH, e errar a ordem
decifra a mensagem corrente sem erro nenhum, mas faz as duas raízes divergirem permanentemente
duas trocas depois — falha silenciosa e cara de diagnosticar:

- um `KEM_ct` recebido, que **completa um ciclo iniciado por nós**, dobra em `RK` *entre* a dobra de
  recepção e a dobra de envio do passo DH;
- um `KEM_ek` recebido, que **abre um ciclo novo**, dobra em `RK` *depois* do passo DH inteiro.

Uma mesma mensagem nunca carrega `KEM_ek` e `KEM_ct` ao mesmo tempo. Os dois bits de `flags` (§6.1)
permitem representar isso, e o decodificador aceita a combinação, mas o emissor não a produz: a
interação entre as duas posições de dobra é frágil demais para o ganho de economizar uma mensagem.

### 5.5 Mensagens fora de ordem

Chaves de mensagem puladas são armazenadas com teto rígido de **1000 chaves** por sessão e
**TTL de 7 dias**. Excedido o teto, a mensagem mais antiga é descartada (a mensagem antiga se
torna indecifrável — é o comportamento desejado, e não um erro de protocolo).

---

## 6. Envelope de transporte (D4)

O envelope da especificação original expunha `Magic`, `Version` e `Packet Type` em claro. Aqui,
o único metadado em claro é o contador, porque o receptor precisa dele para derivar o nonce e
localizar a chave de mensagem.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Counter (u32, big-endian)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|          Ciphertext = AEAD(MK, nonce, AAD=Counter,            |
|                            plaintext = Header ‖ Body ‖ Pad)   |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Poly1305 Tag (16 B)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

`nonce (12 B) = 0x00000000 ‖ 0x00000000 ‖ Counter_be`. A chave muda a cada mensagem pelo ratchet,
então o nonce determinístico é seguro por construção. O `Counter` em claro é o `Ns` da cadeia.

### 6.1 Plaintext interno

```
offset  tam  campo
0       1    packet_type
1       32   dh_pub        chave pública X25519 do ratchet do emissor
33      4    pn            u32 be, mensagens da cadeia anterior
37      2    body_len      u16 be, comprimento real do corpo
39      1    flags         bit0 = carrega KEM_ek, bit1 = carrega KEM_ct
40      ..   kem_material  0, 1184 ou 1088 B conforme flags
..      ..   body          body_len bytes
..      ..   padding       bytes aleatórios CSPRNG até o bucket
```

### 6.2 Tipos de pacote (dentro do ciphertext)

```
0x10 MSG_TEXT            corpo = UTF-8
0x11 MSG_RECEIPT         entrega/leitura
0x12 MSG_TYPING          indicador efêmero, nunca persistido
0x20 FILE_METADATA       manifesto, ver §7
0x21 FILE_SYMBOL         símbolo RaptorQ
0x22 FILE_FEEDBACK       progresso esparso (D6)
0x23 FILE_COMPLETE       confirmação atômica de integridade
0x30 AUDIO_CHUNK         quadro Opus
0x40 CONTROL_PING        keepalive / cover traffic
0x41 CONTROL_REKEM       carrega apenas material de re-KEM
```

`0x01`/`0x02` (handshake) nunca aparecem aqui — vivem fora do envelope, antes de existir sessão.

### 6.3 Buckets de padding (D5)

Todo pacote é preenchido até o próximo bucket. Nenhum outro tamanho jamais vai para o fio.

| Transporte | Buckets de plaintext |
|---|---|
| WebRTC DataChannel | 1024 B, 16384 B |
| Socket TCP local | 1024 B, 65536 B |

Um pacote que não caiba no maior bucket é rejeitado pelo emissor — os produtores (texto, símbolo,
áudio) são dimensionados para caber por construção.

### 6.4 Enquadramento

- **DataChannel**: SCTP já entrega mensagens delimitadas. Nada é acrescentado.
- **Socket TCP**: prefixo `u32` big-endian com o comprimento do envelope. Nenhum magic number, para não dar impressão digital a DPI.

### 6.5 Jitter

Antes de cada envio, atraso amostrado de uma normal truncada em [5 ms, 25 ms] usando CSPRNG.
Documentado em `docs/threat-model.md` como mitigação parcial: não derrota adversário global (D12).

---

## 7. Pipeline de arquivos

### 7.1 Manifesto (`FILE_METADATA`, 0x20)

Serializado em CBOR canônico dentro do corpo:

```
file_id        16 B aleatórios
file_size      u64
symbol_size    u16   16384 no WebRTC, 65536 na LAN
source_blocks  u32   número de source blocks RaptorQ
block_symbols  u16   símbolos-fonte por bloco, máx. 1024 (D6)
merkle_root    32 B  raiz BLAKE3 do plaintext do arquivo
name_encrypted bytes nome original, cifrado no corpo
mime           sempre "application/octet-stream" no fio
```

O nome do arquivo trafega dentro do corpo já cifrado; o MIME real nunca vai ao fio.

### 7.2 Merkle BLAKE3

A raiz é o hash BLAKE3 do plaintext completo — a árvore interna do BLAKE3 (chunks de 1024 B) é o
que permite verificação incremental. O receptor verifica cada source block contra a árvore assim
que o decodifica, e a raiz completa no final, antes do commit atômico.

### 7.3 RaptorQ (D6)

- Ativado apenas em transportes não confiáveis (DataChannel em modo `ordered:false, maxRetransmits:0`).
- Desativado na LAN TCP, que usa transferência por offset com retomada.
- Source blocks de no máximo 1024 símbolos, para limitar o decodificador a ~16 MB de RAM.
- O emissor gera símbolos de reparo continuamente até receber `FILE_FEEDBACK` indicando bloco completo.

### 7.4 Feedback (`FILE_FEEDBACK`, 0x22)

A cada 500 ms o receptor envia `(file_id, block_index, symbols_received, blocks_completed_bitmap)`.
Serve para o emissor parar de gerar reparo e para controle de taxa. Não revela nada além do volume,
que já é observável.

### 7.5 Staging cifrado (D13)

```
K_file    = derive_key("viska-file-key-v1",    session_secret ‖ file_id)
K_staging = derive_key("viska-staging-v1",     K_file)
```

Bytes decodificados são gravados imediatamente em `<app_dir>/staging/<file_id>.staging`, cifrados
com XChaCha20-Poly1305 por página de 64 KB. Nada além de um source block fica em RAM.

Ao completar: recomputa a raiz BLAKE3, compara com `merkle_root`, e só então decifra para o
destino final e apaga o staging. Se abortar, `K_staging` é destruída — o resíduo em flash fica
criptograficamente inacessível, o que é mais confiável que sobrescrever bytes em armazenamento
com wear leveling.

---

## 8. Sinalização remota (D8)

### 8.1 Chave e tópicos

```
K_sig = derive_key("viska-signaling-v1", K_root_da_sessão_pareada)
epoch = floor(unix_time / 3600)
topic(dir, epoch) = hex(BLAKE3_keyed(K_sig, "viska-sig-v1" ‖ dir ‖ u64_be(epoch)))
```

`dir` é `"a2b"` ou `"b2a"`, com A/B fixados pela ordem lexicográfica de `IK_dh`. O assinante
inscreve as épocas `e-1`, `e` e `e+1` para tolerar desvio de relógio.

### 8.2 Payload

SDP e candidatos ICE são cifrados com **XChaCha20-Poly1305** sob `K_sig`, com nonce aleatório de
24 B prefixado, e preenchidos até 1024 B.

> A escolha do XChaCha aqui não é estética. O ChaCha20-Poly1305 comum precisaria de um nonce
> aleatório de 12 B, que seria um terceiro esquema de nonce no protocolo — nem determinístico por
> contador (não há contador confiável na sinalização: as duas pontas republicam offers e candidatos
> em ordem imprevisível), nem com margem de colisão folgada. Reusar a mesma primitiva dos símbolos
> de arquivo elimina o terceiro modo e o código correspondente.

MQTT com `retain = false`, QoS 0. O socket do broker é fechado assim que o DataChannel abre.

### 8.3 Backends

Interface plugável, na ordem de tentativa: MQTT público → relay Nostr → troca manual
(copiar/colar ou QR do payload cifrado). O modo manual não depende de nenhum terceiro.

---

## 9. Descoberta local (D9)

### 9.1 Beacon BLE

```
epoch    = floor(unix_time / 3600)
beacon   = BLAKE3_keyed(K_sig, "viska-beacon-v1" ‖ u64_be(epoch))[0..16]
```

Os 16 bytes são o **UUID de serviço BLE de 128 bits** anunciado — e não manufacturer data, porque
o iOS em background não anuncia esse campo e move os service UUIDs para a overflow area, onde só
são encontrados por um scanner que procure exatamente aquele UUID. O scanner procura os UUIDs das
épocas `e-1`, `e` e `e+1`.

Endereço MAC: aleatorização de endereço privado resolvível habilitada. Nenhum dado de identidade
é anunciado.

### 9.2 mDNS / DNS-SD

Serviço `_viska._tcp` com nome de instância igual ao `beacon` em hex. Mesma rotação por época.

---

## 10. Versionamento

`version = 0x01` no QR e no handshake. Um par que receba uma versão desconhecida aborta e informa
ao usuário para atualizar. Não há downgrade negociado — downgrade negociável é uma vulnerabilidade,
não uma funcionalidade.
