# Modelo de ameaças

## 0. Escopo e proveniência

Este arquivo é citado como leitura obrigatória em `CLAUDE.md`, em `docs/deviations.md` (D12, D13) e
em `rust/logic/src/wire/jitter.rs`, mas não existia no repositório até agora — o conteúdo que deveria
estar aqui vivia disperso, em prosa, dentro de `docs/protocol.md` e `docs/deviations.md`.

`docs/deviations.md` cita repetidamente uma "especificação de arquitetura original" por número de
seção (`§1.1`, `§1.2`, `§3.3` de *outro* documento — não confundir com as seções de mesmo número em
`docs/protocol.md`, que é a versão já reescrita com os desvios D1–D13 incorporados). Essa especificação
original não está neste repositório e não foi encontrada em nenhum outro lugar acessível. Este
documento **não finge citá-la**: toda afirmação abaixo é reconstruída a partir do que existe e é
verificável hoje — `CLAUDE.md`, `docs/protocol.md`, `docs/deviations.md` e os doc-comments dos módulos
Rust — não uma tradução de um documento que não pode ser lido.

Se uma futura revisão localizar a especificação original, os pontos abaixo que hoje dizem "motivado
por D2/D12/etc." devem ser conferidos contra ela e as referências a `§1.1`/`§1.2` em `deviations.md`
substituídas por algo verificável.

---

## 1. Adversários considerados

### 1.1 Infraestrutura de sinalização (broker MQTT, relay)

Tratada como hostil por padrão — nunca como parte da base de confiança do sistema (`CLAUDE.md`, "nenhuma
infraestrutura confiável"). Um broker público (`broker.emqx.io`, `test.mosquitto.org`) pode registrar
tudo que passa por ele: quais tópicos existem, quando, de que IP, com que tamanho de payload. Nada
impede um operador de broker malicioso ou uma ordem judicial contra ele.

### 1.2 Rede em trânsito, incluindo "Harvest Now, Decrypt Later" (HNDL)

Um adversário que grava todo o tráfego cifrado hoje, na esperança de decifrá-lo quando computadores
quânticos capazes de quebrar X25519 existirem. É a motivação central de D2 (ratchet com re-KEM
periódico em ML-KEM-768): sem isso, a recuperação pós-comprometimento do ratchet dependeria só de
X25519, e esse adversário venceria assim que tivesse o hardware.

### 1.3 Observador de timing e volume

Alguém que veja o tráfego cifrado passar (rede local, ISP, ponto intermediário) e tente inferir
metadados — quando duas pessoas conversam, por quanto tempo, com que volume — sem decifrar nada.

### 1.4 Acesso físico ao aparelho

Alguém que tenha o aparelho na mão, ligado ou desligado, desbloqueado uma vez ou nunca. Para a maioria
dos usuários reais este é o adversário mais provável, e é o que D13 trata explicitamente (a
especificação original mal cobre esse caso, além de "usar Secure Enclave/KeyStore").

### 1.5 Terceiro tentando provar que uma conversa ocorreu

Não é um adversário de rede — é qualquer parte (um dos próprios participantes, um tribunal, um
empregador) tentando produzir evidência transferível de que duas identidades específicas se
comunicaram, ou do que foi dito. É a motivação de D1: nenhuma assinatura assimétrica por mensagem,
porque um transcript assinado é exatamente esse tipo de prova.

### 1.6 Contraparte mal-intencionada ou com implementação divergente

Um contato pareado (a `IK_dh` dele já foi verificada presencialmente) que envie mensagens malformadas,
cabeçalhos de ratchet forjados, ou fale uma versão diferente do protocolo. Não é um adversário
criptográfico no sentido de quebrar uma primitiva, mas o código de decodificação de bytes vindos da
rede (`wire/`, `crypto/ratchet.rs`) precisa nunca entrar em pânico nem corromper estado ao processá-lo.

---

## 2. O que é defendido, por controle

| Adversário | Mitigação | Onde |
|---|---|---|
| HNDL (1.2) | X25519 + ML-KEM-768 no handshake; re-KEM periódico no ratchet (256 msgs ou 24h) | `crypto/handshake.rs`, `crypto/ratchet.rs` §5.4 |
| Prova transferível de conversa (1.5) | Nenhuma assinatura assimétrica por mensagem; autenticação por DH contra `IK_dh` já trocada no QR | `crypto/handshake.rs` (D1) |
| Aparelho comprometido, chave antiga recuperável (1.4, parcial) | Double Ratchet: forward secrecy e recuperação pós-comprometimento | `crypto/ratchet.rs` (D2) |
| Correlação de longo prazo por broker hostil (1.1) | Tópico de sinalização rotativo por época, não um identificador estático do par | `docs/protocol.md` §8.1 (D8) |
| DPI / fingerprint de tráfego | Sem `Magic`/`Version`/`Packet Type` em claro; só o contador; dois tamanhos de bucket possíveis por transporte | `docs/protocol.md` §6, §6.3 (D4, D5) |
| Reuso de (chave, nonce) | Nonce determinístico só quando a chave é de uso único (mensagens do ratchet); nonce aleatório de 192 bits em todo o resto | `docs/protocol.md` §6, §7.5, §8.2 (D11) |
| Contraparte enviando bytes malformados (1.6) | `.get()`/`checked_add` em todo offset vindo da rede; nunca indexação direta não validada; property tests de "nunca panica" | `wire/plaintext.rs`, `wire/envelope.rs` |
| Aparelho apreendido, extração de disco (1.4) | Banco cifrado (SQLCipher) dentro do Rust, chave nunca no heap gerenciado do Dart; `zeroize` em buffers temporários | `docs/deviations.md` D7, D13 |

---

## 3. O que **não** é defendido, explicitamente

- **IP real dos dois pares.** Numa conexão P2P direta (WebRTC), cada lado vê o IP real do outro, e os
  servidores STUN veem os dois. O payload de sinalização (SDP/candidatos ICE) é cifrado, mas o fato de
  que a conexão acontece, quando e com que IPs não é escondido. Aceito e declarado, não mitigado — o
  modo local (BLE/LAN) não tem essa exposição (D12).
- **Adversário de timing global ou multiponto.** O jitter de [5, 25] ms (§6.5 do protocolo) atrapalha
  correlação grosseira de um único ponto de observação, mas não derrota alguém que observe as duas
  pontas de um enlace direto simultaneamente, nem correlação por volume agregado ou momento de conexão
  (D12).
- **NAT simétrico sem relay.** O projeto não usa TURN — um relay é exatamente o tipo de infraestrutura
  que a raiz de confiança do projeto rejeita. Uma fração das conexões entre NATs simétricos
  simplesmente não fecha; isso é tratado como limitação de produto (a UI deve falhar de forma explícita
  e sugerir o modo local), não como bug a corrigir.
- **Volume e frequência de mensagens/arquivos.** O feedback de transferência de arquivo (`FILE_FEEDBACK`,
  §7.4) e o próprio ato de trocar mensagens revelam volume aproximado a quem observa o tráfego cifrado;
  o protocolo não tenta esconder isso (é tratado como já observável de qualquer forma).
- **Comprometimento do aparelho antes do primeiro uso.** Se o aparelho já estiver comprometido (malware,
  keylogger, câmera do QR interceptada) antes do pareamento, nenhuma primitiva aqui ajuda — a raiz de
  confiança é o pareamento presencial em si.

---

## 4. Segurança em repouso

Resumo de D13 (`docs/deviations.md`): chave mestra embrulhada no KeyStore/Secure Enclave e
desembrulhada só dentro do Rust; `zeroize` em todo segredo que passa por buffer temporário;
`allowBackup=false`; `FLAG_SECURE`; bloqueio por biometria com auto-lock; apagamento de emergência por
destruição de chave (crypto-shredding); staging de arquivo cifrado com chave descartável por
transferência; teclado sem autocorreção nem sugestões; zero SDK de analytics, crash reporting ou
publicidade; build reproduzível.

---

## 5. Como usar este documento

`CLAUDE.md` já exige ler `docs/protocol.md` antes de implementar uma seção do protocolo. Este arquivo
é o complemento: antes de escrever ou revisar qualquer código que toque rede (sessão, sinalização,
transporte), confira se a mudança proposta move algo da seção 2 (defendido) para a seção 3 (não
defendido) sem uma decisão explícita do usuário — exatamente a regra não-negociável de `CLAUDE.md`
sobre as três propriedades que o projeto existe para garantir.
