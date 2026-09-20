# Desvios da especificação de arquitetura original

A especificação de arquitetura recebida define o produto. Este documento registra os pontos em que
a implementação se afasta dela, sempre por uma de duas razões: a letra da spec contradiz um objetivo
declarado pela própria spec, ou é inviável nas plataformas alvo.

Cada desvio tem um identificador estável (D1–D15). O código e o `protocol.md` referenciam esses
identificadores. Reverter qualquer um para a letra original é uma decisão de produto, não técnica —
o custo de cada reversão está anotado.

---

## D1 — Handshake sem assinatura Ed25519
**Spec:** §3, mensagens de handshake "assinadas com Ed25519".
**Aqui:** AKE no estilo PQXDH; a autenticação vem de DH contra as chaves de identidade trocadas no QR.

A spec pede deniabilidade no §3.3 e assinatura de handshake no §3. As duas coisas não coexistem: um
transcript assinado é prova transferível de que aquele aparelho participou daquela sessão. A
deniabilidade do §3.3 protegeria apenas o conteúdo das mensagens, deixando a existência da conversa
provada — que costuma ser o dado mais sensível dos dois.

Ed25519 continua existindo, assinando exatamente uma coisa: o payload do QR Code. Assinar uma chave
pública em um pareamento presencial não prova conversa nenhuma.

**Custo de reverter:** baixo no código, alto na segurança. Não recomendado.

---

## D2 — Ratchet por mensagem
**Spec:** §3.2, uma `K_session` derivada uma vez.
**Aqui:** Double Ratchet com re-encapsulamento ML-KEM periódico.

Com chave de sessão única, quem obtiver a chave lê tudo: as mensagens passadas que ainda estiverem
no aparelho e todas as futuras, indefinidamente. Um telefone apreendido, desbloqueado uma vez,
entrega a conversa inteira para sempre.

O ratchet dá forward secrecy (mensagem antiga não é recuperável a partir do estado atual) e
recuperação pós-comprometimento (depois de um round-trip, o atacante que roubou o estado perde o
acesso). O re-KEM periódico garante que essa recuperação também seja pós-quântica — sem ele, a
recuperação dependeria só de X25519 e o adversário HNDL do §1.2 voltaria a ganhar.

**Custo de reverter:** baixo no código, muito alto na segurança. Não recomendado.

---

## D3 — Safety number de 60 dígitos
**Spec:** §2.3, 6 dígitos decimais.
**Aqui:** 12 grupos de 5 dígitos, ~199 bits.

6 dígitos são ~20 bits. Gerar pares de chaves até que o safety number resultante colida com um alvo
custa ~10⁶ tentativas, o que é questão de segundos. O número serve justamente para detectar troca de
chave; com 20 bits, ele não detecta.

**Custo de reverter:** nenhum no código; a UI fica mais curta e a verificação vira teatro.

---

## D4 — `Magic` e `Packet Type` fora do cabeçalho em claro
**Spec:** §7, envelope com `Magic (0x5350)`, `Version`, `Packet Type` e `Reserved` em texto claro.
**Aqui:** só o contador de 4 bytes em claro; tipo, comprimento e corpo dentro do AEAD.

O §6 dedica uma seção inteira a impedir que o observador distinga texto de voz de arquivo — e o §7
põe exatamente essa informação em claro no byte 3 de cada pacote. O `Magic` fixo, além disso, é uma
impressão digital perfeita para DPI: basta procurar `0x5350` para marcar todo tráfego do app.

O contador fica em claro porque o receptor precisa dele para derivar o nonce e localizar a chave de
mensagem antes de conseguir decifrar qualquer coisa. Ele entra como AAD, então não pode ser
adulterado em silêncio.

**Custo de reverter:** nenhum no código; perde-se o §6 inteiro.

---

## D5 — Tamanho de bloco por transporte
**Spec:** §5.1 e §6.1, blocos fixos de 65.536 bytes.
**Aqui:** 16 KB no DataChannel WebRTC, 64 KB no socket TCP local.

O tamanho máximo de mensagem do DataChannel é negociado no SDP e 64 KB fica acima do que várias
pilhas aceitam de forma interoperável. Mensagens grandes também bloqueiam o stream SCTP inteiro
enquanto são remontadas.

A propriedade que o §6.1 quer — o observador ver apenas dois tamanhos possíveis — é preservada:
continuam sendo dois buckets, só que dimensionados ao transporte.

**Custo de reverter:** conexões que falham silenciosamente em parte dos aparelhos.

---

## D6 — RaptorQ só em canal não confiável, com feedback esparso
**Spec:** §5.2, RaptorQ sempre, sem ACKs.
**Aqui:** RaptorQ + DataChannel não confiável e não ordenado; na LAN TCP, transferência por offset.
Feedback de progresso a cada ~500 ms.

Um DataChannel em modo confiável já retransmite o que se perde. Somar RaptorQ ali paga o overhead de
um código de fonte para reparar perdas que o SCTP já reparou — duas camadas fazendo o mesmo trabalho.
O ganho real do RaptorQ aparece quando o canal é não confiável, e é por isso que o canal passa a ser
configurado assim.

"Zero ACK" também não fecha por conta própria: sem nenhum retorno, o emissor não sabe quando parar de
gerar símbolos de reparo nem a que taxa transmitir, e um emissor sem controle de congestionamento em
rede móvel derruba a própria conexão. O feedback é esparso e só informa contagem por bloco, que é
volume — dado que o observador já enxerga.

Particionar em source blocks de no máximo 1.024 símbolos é o que mantém a promessa do §5.3: o
decodificador RaptorQ precisa do bloco inteiro em RAM, então um bloco único de 500 MB violaria
"nenhum arquivo é montado na memória volátil" pelo próprio decodificador.

**Custo de reverter:** overhead duplicado e risco de esgotar RAM em arquivos grandes.

---

## D7 — Banco de dados dentro do Rust
**Spec:** §8, "sqlite via SQLCipher" na camada Flutter.
**Aqui:** `rusqlite` com SQLCipher dentro do core Rust; o Dart recebe só handles opacos.

O plugin `sqlcipher_flutter_libs` está marcado como EOL na pub.dev. Mais importante: material de
chave que atravessa o FFI cai no heap gerenciado do Dart, onde não pode ser zerado de forma
confiável — o GC move e copia objetos, e cópias de uma chave podem sobreviver em memória por tempo
indeterminado, incluindo em um heap dump.

**Custo de reverter:** perda de controle sobre o tempo de vida dos segredos.

---

## D8 — Rotação por época na sinalização
**Spec:** §4.2, tópico derivado do `SharedSecret`.
**Aqui:** tópico derivado de `SharedSecret` **e** da época atual, com janela de três épocas.

Um tópico estático é um identificador permanente do par dentro do broker público. O §1.2 declara o
broker como potencialmente hostil; um broker hostil com tópico estático constrói o grafo social e o
histórico de atividade de cada par ao longo de meses, sem decifrar nada.

A janela de três épocas (anterior, atual, seguinte) existe porque dois celulares com relógios alguns
minutos dessincronizados nunca se encontrariam perto da virada da hora.

**Custo de reverter:** correlação de longo prazo por um adversário que a spec já assume hostil.

---

## D9 — Transporte local realista entre Android e iOS
**Spec:** §4.1 e §8, Wi-Fi Direct + `nearby_connections` + `multipeer_connectivity`.
**Aqui:** mDNS/DNS-SD + TCP como base universal; Wi-Fi Aware e MultipeerConnectivity como
aceleradores por plataforma; BeaconID BLE no UUID de serviço, não em manufacturer data.

Três problemas na spec original:
1. `nearby_connections` depende do Google Play Services, o que contradiz a premissa de "independência
   de infraestrutura proprietária" do §1.1.
2. Wi-Fi Direct não existe no iOS, e Nearby Connections não conversa com MultipeerConnectivity. Do
   jeito descrito, Android e iOS nunca se conectam offline.
3. O iOS em background não anuncia manufacturer data e move service UUIDs para a overflow area. Um
   BeaconID em manufacturer data simplesmente não é visto — que é o cenário principal de uso.

**Custo de reverter:** dependência do Google, e Android↔iOS offline não funciona.

---

## D10 — `libcrux-ml-kem` no lugar de `ml-kem`
**Spec:** §8, `ml-kem` (RustCrypto).
**Aqui:** `libcrux-ml-kem`, com `ml-kem` disponível atrás de uma feature.

A documentação do próprio `ml-kem` avisa que a implementação não foi auditada. `libcrux-ml-kem` é
formalmente verificada (HACL*/F*) e usada em produção. Para uma primitiva cuja falha compromete
justamente a resistência quântica que motiva o projeto inteiro, a diferença importa.

Os dois ficam atrás do trait `Kem`, então a troca é de uma linha no `Cargo.toml`.

**Custo de reverter:** uma linha; perde-se a verificação formal.

---

## D11 — XChaCha20-Poly1305 nos símbolos de arquivo
**Spec:** §5, "ChaCha20-Poly1305 com Nonce Sequencial".
**Aqui:** nonce determinístico de 12 B nas mensagens do ratchet (onde a chave muda a cada mensagem),
nonce aleatório de 24 B nos símbolos de arquivo.

Reusar um par (chave, nonce) em ChaCha20-Poly1305 revela o XOR dos plaintexts e permite forjar tags.
Um contador sequencial sobrevive mal a transferências retomadas depois de queda de conexão, troca de
transporte ou restauração de backup — exatamente os cenários que o §5 se propõe a suportar. Com 192
bits de nonce aleatório, a colisão deixa de ser uma preocupação operacional.

**Custo de reverter:** risco de catástrofe criptográfica em um caso de uso que a spec prevê.

---

## D12 — Limites declarados de padding e jitter
**Spec:** §6.2, jitter de 5–25 ms contra análise de timing.
**Aqui:** mantido, com a limitação documentada no threat model e avisada na UI.

Jitter dessa ordem atrapalha correlação grosseira, mas não derrota um adversário que observe os dois
extremos de um enlace direto. E há um vazamento maior e não mencionado na spec: em conexão P2P
direta, cada par conhece o IP real do outro, e os servidores STUN conhecem os dois.

Decisão do projeto: aceitar e declarar, em vez de sugerir uma proteção que não existe. O modo local
(BLE/LAN) não tem essa exposição.

**Custo de reverter:** nenhum — é documentação, não código.

---

## D13 — Segurança em repouso dentro do aparelho
**Spec:** não coberto além de "Secure Enclave / KeyStore".
**Aqui:** conjunto explícito de medidas, detalhado em `docs/threat-model.md`.

A spec trata com profundidade o adversário de rede e quase não trata o adversário que tem o aparelho
na mão — que, para a maior parte dos usuários reais, é o mais provável dos dois.

Resumo: chave mestra embrulhada no KeyStore/Secure Enclave e desembrulhada só dentro do Rust;
`zeroize` em todo segredo; `allowBackup=false`; `FLAG_SECURE`; bloqueio por biometria com auto-lock;
apagamento de emergência por destruição de chave (crypto-shredding); staging cifrado com chave
descartável; teclado sem autocorreção nem sugestões; zero SDK de analytics, crash reporting ou
publicidade; build reproduzível.

**Custo de reverter:** o adversário mais provável passa a ser o menos tratado.

---

## D14 — `dh_pub` do ratchet em claro no envelope
**Spec (versão anterior deste protocolo):** §6.1, `dh_pub` dentro do plaintext cifrado, ao lado do
corpo.
**Aqui:** `dh_pub` no cabeçalho em claro do envelope, ao lado do contador, incluído no AAD.

Descoberto ao planejar a camada `session` (Fase 3): a versão anterior é circular. Para uma mensagem
que dispara uma troca de cadeia DH (§5.2), `RatchetState::receiving_key` precisa do `dh_pub` do
cabeçalho **antes** de conseguir derivar a chave — o passo `ratchet_dh_step` calcula
`X25519(DHs_atual, dh_pub_recebido)`, e não há como decifrar primeiro para descobrir esse valor.
Confirmado lendo `crypto/ratchet.rs` diretamente, não é uma leitura ambígua da spec.

A correção segue o Double Ratchet do Signal: `dh_pub` sai do plaintext cifrado e entra no cabeçalho
em claro do envelope, coberto pelo AAD (qualquer adulteração ainda é detectada pelo AEAD, só não é
mais escondida). O valor exposto é uma chave X25519 **efêmera**, trocada a cada poucas mensagens —
nunca a identidade de longo prazo (`IK_dh`). É um vazamento estritamente menor que os já aceitos em
D12 (o IP real de cada par, inerente a uma conexão P2P direta).

A alternativa mais cara — manter `dh_pub` escondido com header encryption completo (chaves de
cabeçalho simétricas `HK`/`NHK`, derivadas por geração de cadeia) — preservaria a promessa original de
D4 ("nada além do contador em claro"), mas exige uma máquina de estados nova dentro de
`crypto/ratchet.rs`, um projeto à parte. Descartada para a Fase 3 pelo custo, não por ser inviável.

**Custo de reverter:** header encryption completo — projeto à parte, não uma correção pontual.

---

## D15 — `K_staging` de um segredo local por transferência, não do ratchet
**Spec:** `docs/protocol.md` §7.5, `K_file = derive_key("viska-file-key-v1", session_secret ‖ file_id)`
— `session_secret` sugere uma chave do ratchet.
**Aqui:** um segredo aleatório de 32 B (`transfer_secret`), gerado por `crate::util::rng` uma vez por
transferência, guardado cifrado no banco local enquanto a transferência está ativa e apagado ao
completar ou abortar. `K_file`/`K_staging` derivam dele, nunca de uma chave do ratchet.

Descoberto ao planejar a Fase 4: `session::Session` nunca expõe chave de mensagem para fora de si —
nem `encrypt_outgoing` nem `decrypt_incoming` devolvem a `MK` usada — e essa é uma propriedade
deliberada da camada de sessão, não um descuido. Romper isso pela primeira vez só para alimentar o
staging custaria mais em superfície de API do que resolveria.

Mais decisivo: uma `MK` do ratchet é de uso único por desenho (§5.3) — é exatamente isso que dá à
sessão sigilo de encaminhamento. Uma transferência de arquivo grande precisa sobreviver a queda de
conexão e retomar depois (D6, D9), reabrindo o mesmo `.staging` com a mesma chave — impossível se a
chave de origem for, por construção, irrecuperável depois de consumida uma vez. Um segredo local
dedicado, gerado uma vez por transferência e mantido (cifrado em repouso pelo banco, já coberto por
D7/D13) até o fim ou o aborto, resolve as duas pontas ao mesmo tempo: "abortar destrói a chave"
(crypto-shredding, §7.5) fica sob controle total do dispositivo — basta apagar a linha do banco — e
retomar uma transferência não depende de reconstruir um estado de ratchet específico.

**Custo de reverter:** perder a capacidade de retomar uma transferência grande após queda de conexão
sem recomeçar do zero, a menos que uma primitiva nova de chave "recuperável mas de uso único" seja
desenhada dentro do ratchet — projeto à parte.
