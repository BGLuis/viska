# Fase 1 — núcleo criptográfico em Rust

| Campo | Valor |
|-------|-------|
| **Status** | 🟡 Parcial |
| **Escopo entregue** | Identidade, pareamento, DH, ML-KEM-768, handshake híbrido deniável, Double Ratchet, AEAD, KDF e o envelope de transporte inteiro. **Ficou de fora:** o banco SQLCipher, previsto no recorte original da fase |
| **Esforço real** | Não mensurável em dias-dev — quatro agentes em paralelo, sem registro de horas |
| **Commit base** | Nenhum · `git log` → *does not have any commits yet* |

---

## 1. Sumário executivo

A Fase 1 entregou 4.163 linhas de Rust cobrindo do pareamento óptico ao envelope que vai para o fio.
O caminho criptográfico está completo e testado: duas identidades se pareiam por QR, executam um AKE
híbrido X25519 + ML-KEM-768 sem nenhuma assinatura, e conversam através de um Double Ratchet com
re-encapsulamento pós-quântico periódico.

O trabalho foi feito por quatro agentes em paralelo, cada um dono de exatamente um arquivo ou
diretório, com `docs/protocol.md` como contrato. Esse arranjo produziu o resultado mais valioso da
fase, que não era o código: **seis defeitos foram encontrados, e cinco deles estavam na
especificação ou no código que eu mesmo havia escrito**, não no trabalho dos agentes. Dois eram
fatais — um teria quebrado toda conversa na primeira mensagem, outro anulava em silêncio a proteção
contra viés que a própria função existia para dar.

O que ficou de fora é conhecido e está registrado: o módulo de persistência, os vetores oficiais do
FIPS 203 e a profundidade de teste que o critério de aceite pedia.

**Veredicto:** o núcleo está correto no que testa, e o que ele testa cobre os caminhos que importam
— mas nenhuma linha dele jamais rodou fora de `x86_64-unknown-linux-gnu`, e o critério de aceite
original da fase não foi integralmente cumprido.

---

## 2. Impactos e ganhos

Esta fase não substitui nada, então não há eixo antes/depois de desempenho. A tabela registra o que
passou a existir, com a origem de cada número.

| Métrica | Antes | Depois | Fonte |
|---|---|---|---|
| Linhas de Rust em `rust/src/` | 246 | 4.163 | `find src -name '*.rs' \| xargs wc -l` |
| Testes automatizados | 0 | 82 | `cargo test` |
| Tempo da suíte completa | — | 24,89 s | `cargo test`, medido |
| Avisos de `clippy -D warnings` | — | 0 | `cargo clippy --all-targets -- -D warnings` |
| Defeitos encontrados e corrigidos | — | 6 | seção 4 |

Distribuição dos 82 testes, por módulo, medida com
`cargo test 2>&1 | grep "^test " | sed ... | sort | uniq -c`:

| Módulo | Testes | Módulo | Testes |
|---|---|---|---|
| `crypto::handshake` | 13 | `crypto::safety_number` | 4 |
| `crypto::aead` | 10 | `crypto::identity` | 4 |
| `wire::plaintext` | 9 | `wire::packet_type` | 3 |
| `crypto::ratchet` | 9 | `crypto::kem` | 3 |
| `crypto::pairing` | 7 | `wire::transport` | 2 |
| `wire::framing` | 5 | `wire::jitter` | 2 |
| `util::rng` | 5 | `crypto::dh` | 2 |
| `wire::envelope` | 4 | | |

O ganho de correção do `util::rng` tem número medido e vale registrar separadamente: os dois testes
de jitter passaram de **38,87 s por amostra** — medido em binário isolado com a fórmula antiga — para
**0,00 s** na suíte inteira. Com 10.000 amostras, o teste antigo levaria ~108 horas `[modelado]`,
por extrapolação linear da medição. O defeito não era lentidão; era não-terminação prática.

---

## 3. Etapas executadas

Na ordem real, que foi de paralelização progressiva e não a sequência linear do plano.

1. **Base escrita à mão** — `util/{rng,time,encoding}`, `crypto/{kdf,dh,kem,identity,safety_number,
   pairing}`. Compilação de validação antecipada contra a API do `libcrux-ml-kem` antes de escrever
   mais código sobre ela, o que confirmou os tamanhos do FIPS 203 (1.184 / 2.400 / 1.088 / 32 B).

2. **Onda 1, dois agentes em paralelo** — `crypto/aead.rs` e `crypto/handshake.rs`. Arquivos
   declarados em `crypto/mod.rs` como *placeholder* antes do despacho, para que o crate compilasse e
   cada agente pudesse rodar `cargo test` sem depender do outro.

3. **Onda 2, dois agentes em paralelo** — `crypto/ratchet.rs` e o diretório `wire/`. O seam entre os
   dois foi desenhado de propósito: o ratchet mexe em chaves e não serializa; o `wire` mexe em bytes
   e não conhece chave. Foi isso que tornou a paralelização possível sem colisão.

4. **Correção do `util/rng.rs`** — despachada como tarefa isolada depois que o diagnóstico ficou
   pronto, com a aritmética já verificada numericamente e passada no enunciado.

5. **Desvio registrado:** o módulo `store/` com SQLCipher, que o recorte original punha nesta fase,
   **não foi feito**. A decisão foi consciente: ele não bloqueia nenhum teste do núcleo, e depende
   de escolhas de integração com KeyStore e Secure Enclave que pertencem mais à fronteira FFI que ao
   núcleo. Foi realocado para a Fase 2, onde é pré-requisito real.

6. **Desvio registrado:** o agente do `wire` parou duas vezes em laço de espera por um subprocesso,
   sem entregar relatório. O código estava completo e correto; a validação foi feita por leitura
   direta e execução própria da suíte, em vez de insistir com o agente.

---

## 4. Detalhes de implementação

### 4.1 O contexto de KDF do passo de cadeia era um erro fatal na especificação

`docs/protocol.md` §5.3 + `rust/src/crypto/ratchet.rs:104-124`

A especificação mandava avançar `CKs` com `viska-send-chain-v1` e `CKr` com `viska-recv-chain-v1`.
Está errado, e quebra **toda conversa na segunda mensagem**: a cadeia de envio de um par e a cadeia
de recepção do outro são o mesmo segredo evoluindo em paralelo nos dois aparelhos. Separação de
domínio existe para materiais de chave diferentes, não para o mesmo valor visto de dois lados.

```rust
// rust/src/crypto/ratchet.rs:123-124
material[kdf::KEY_LEN] = 0x02;
let next_key = kdf::derive(kdf::context::SEND_CHAIN, &material);
```

O agente do ratchet identificou isso por um teste de entrega fora de ordem que falhava, não por
leitura. A constante `RECV_CHAIN` foi removida de `crypto/kdf.rs` para que ninguém volte a usá-la, e
a especificação foi corrigida com a justificativa junto.

### 4.2 O estado do ratchet só é confirmado depois que o AEAD abre

`rust/src/crypto/ratchet.rs` — `receiving_key`, `commit_receive`, `discard_receive`

`receiving_key` calcula tudo dentro de um `PendingReceive` privado e **não** toca em `RK`, `DHs`,
`DHr`, `CKs`, `CKr` nem `PN`. A camada de sessão chama `commit_receive()` só depois que o AEAD
autentica. A alternativa — mutar direto — permite que um cabeçalho forjado que alcance o ramo de
passo DH ou de re-KEM dessincronize a sessão de forma permanente, sem que nenhuma mensagem
legítima jamais decifre de novo. É negação de serviço barata e irreversível.

A exceção é a consulta ao cache de chaves puladas, que só lê uma chave já derivada e já confirmada.

### 4.3 A posição da dobra do re-KEM não comuta com o passo DH

`docs/protocol.md` §5.4, acrescentado depois da implementação

Um `KEM_ct` que completa um ciclo iniciado por nós dobra em `RK` *entre* a dobra de recepção e a de
envio do passo DH. Um `KEM_ek` que abre ciclo novo dobra *depois* do passo inteiro. Qualquer outra
ordem decifra a mensagem corrente sem erro algum e faz as raízes divergirem duas trocas depois.

O agente levou três iterações de teste instrumentado para fixar isso. A especificação não dizia nada
a respeito — agora diz, como texto normativo.

### 4.4 O safety number truncava em silêncio

`rust/src/crypto/safety_number.rs`

Os grupos estavam tipados como `u16`, que comporta até 65.535. Grupos de cinco dígitos vão até
99.999. Todo valor acima de 65.535 daria a volta, reduzindo a entropia efetiva e — pior — fazendo
dois pares diferentes exibirem o mesmo número com probabilidade muito maior que a nominal. Pego pelo
teste `grupos_ficam_na_faixa_de_cinco_digitos`, que não compilava.

### 4.5 A rejeição sem viés do `util::rng` não rejeitava nada útil

`rust/src/util/rng.rs` — `rejection_limit`

A fórmula original, `u32::MAX - (u32::MAX % bound) - (bound - 1)`, tinha dois defeitos simultâneos.
Com `bound = u32::MAX` colapsava para `limit = 1`, aceitando 2 valores em 2³². E a contagem de
aceitos nunca era múltipla de `bound` — ou seja, **o viés que a função existia para eliminar
continuava lá**, para todo valor testado.

```rust
// rust/src/util/rng.rs — 2^32 mod bound, em duas etapas porque 2^32 não cabe em u32
let rem = ((u32::MAX % bound) + 1) % bound;
u32::MAX - rem
```

O invariante agora está travado em teste: `(rejection_limit(bound) + 1) % bound == 0` para
`bound ∈ {2, 3, 7, 1000, 100_000, u32::MAX}`.

### 4.6 O backend alternativo de KEM nunca havia compilado

`rust/Cargo.toml` · `rust/src/crypto/kem.rs`

O bloco `kem-rustcrypto` foi escrito sem nunca ser compilado, e a justificativa que eu havia dado
para o trait `Kem` — "trocar de backend é uma linha no `Cargo.toml`" — era falsa. Removido. O trait
permanece, agora com justificativa honesta: ponto de troca para quando o `libcrux` 0.0.x quebrar a
API, não um segundo backend pronto. `cargo build --all-features` e `--no-default-features` entraram
na verificação para que a regressão não se repita em silêncio.

### 4.7 A sinalização pedia um terceiro esquema de nonce

`docs/protocol.md` §8.2

A especificação pedia ChaCha20-Poly1305 com nonce **aleatório** de 12 B para o SDP — nem
determinístico por contador como as mensagens do ratchet, nem com a margem de 24 B dos símbolos de
arquivo. Trocado para XChaCha20-Poly1305, que já existe em `crypto/aead.rs` e elimina o terceiro
modo junto com o código que ele exigiria.

---

## 5. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/src/crypto/{kdf,dh,kem,identity,safety_number,pairing}.rs` | **novo** — base escrita à mão |
| `rust/src/crypto/aead.rs` | **novo** — 281 linhas, ChaCha20 e XChaCha20 |
| `rust/src/crypto/handshake.rs` | **novo** — 551 linhas, AKE deniável |
| `rust/src/crypto/ratchet.rs` | **novo** — 1.017 linhas, Double Ratchet com re-KEM |
| `rust/src/wire/` (7 arquivos) | **novo** — 1.015 linhas, envelope, padding, enquadramento, jitter |
| `rust/src/util/rng.rs` | reescrita de `below`, 36 → 170 linhas |
| `rust/src/crypto/kdf.rs` | `RECV_CHAIN` **apagado**, com justificativa no lugar |
| `rust/Cargo.toml` | backend `kem-rustcrypto` **apagado**; `features` esvaziado |
| `docs/protocol.md` | §5.3 corrigido, §5.4 acrescentado, §8.2 corrigido, §1 atualizado |

---

## 6. Verificação executada

**Rodado e passando nesta sessão (`cargo test`, de dentro de `rust/`):**

- [x] 82 testes, 0 falhas, 24,89 s.
- [x] `crypto::pairing::rejeita_qualquer_bit_adulterado` — 145 bytes × 8 bits = 1.160 adulterações,
      todas rejeitadas.
- [x] `crypto::aead::vetor_rfc8439_secao_2_8_2` — vetor oficial do RFC 8439, conferido byte a byte
      na cifragem e na decifragem. É o único teste da suíte que valida a implementação contra uma
      autoridade externa, e não contra si mesma.
- [x] `crypto::handshake` — 13 testes, incluindo dois laços exaustivos de adulteração bit a bit sobre
      INIT e RESP com ML-KEM real.
- [x] `crypto::ratchet` — 9 testes: conversa de 1.000 mensagens alternadas, entrega fora de ordem,
      mensagem perdida, forward secrecy, passo DH com propagação de `PN`, ciclo de re-KEM, teto de
      chaves puladas, e cabeçalho com `dh_pub` de ordem baixa.
- [x] `wire::plaintext::decode_nunca_entra_em_panico` — property test sobre bytes arbitrários.
- [x] `cargo clippy --all-targets -- -D warnings` — zero avisos.
- [x] `cargo build --all-features` e `cargo build --no-default-features`.

**Não executado:**

- [ ] Vetores oficiais de *known-answer test* do FIPS 203 para ML-KEM-768. Ver seção 7, item 1.
- [ ] Conversa de 10.000 mensagens, que era o critério de aceite original. O teste implementado usa
      1.000 (`crypto/ratchet.rs:752`).
- [ ] Qualquer execução fora de `x86_64-unknown-linux-gnu`.
- [ ] `cargo audit` — a ferramenta não foi instalada nem executada.

---

## 7. O que não foi verificado

1. **Os KATs do FIPS 203 não existem, e o critério de aceite da fase os exigia.** Os três testes de
   `crypto::kem` verificam ida e volta, tamanhos e não-colisão entre pares distintos — tudo
   autoconsistente. Nenhum confronta a implementação com os vetores publicados pelo NIST. Se o
   `libcrux-ml-kem` tivesse um defeito de interoperabilidade, esta suíte não o veria. É a lacuna de
   verificação mais séria da fase, e o custo de fechá-la é baixo.

2. **A profundidade do teste de ratchet é 10× menor que o planejado.** 1.000 mensagens em vez de
   10.000. Como o gatilho de re-KEM é a cada 256 mensagens, 1.000 exercita cerca de quatro ciclos —
   suficiente para pegar erro de ordem de dobra, insuficiente para revelar acúmulo lento de estado.

3. **A convergência de `RK` entre os dois lados não é verificada diretamente.** O agente constatou
   experimentalmente que, numa conversa alternada normal, as duas raízes nunca são iguais em um
   instante arbitrário — cada lado está sempre um passo DH à frente do que o outro usa como
   referência. O teste foi reescrito para verificar que as mensagens continuam decifrando e que cada
   `RK` muda ao completar sua metade do ciclo. É mais fraco que comparar raízes em pontos
   correspondentes do protocolo, e essa versão mais forte continua por escrever.

4. **O estouro do contador de 32 bits do envelope nunca foi exercido.** Nada no código impede uma
   cadeia de chegar a 2³² mensagens, e nenhum teste força esse limite. É teórico no uso normal, e é
   exatamente o tipo de limite que um par malicioso tentaria alcançar.

5. **Nenhum teste de tempo constante.** `subtle` é usado em `util/encoding::ct_eq`, mas não há
   verificação de que os caminhos sensíveis estejam livres de ramificação dependente de segredo, nem
   medição de variação de tempo. Para um app móvel isso é aceitável como risco residual; para uma
   auditoria, não.

6. **Nada foi revisado por um criptógrafo humano.** O protocolo é uma composição de construções
   conhecidas — X3DH, PQXDH, Double Ratchet — mas a composição é própria, e composição é onde
   protocolos falham. A suíte prova consistência interna, não segurança.

---

> Nenhum item deste relatório foi executado em aparelho Android ou iOS. Toda a verificação rodou no
> host `x86_64-unknown-linux-gnu`, em *working tree* não versionado — não há commit a citar. As
> lacunas dos itens 1 e 2 da seção 7 são pendências reais do critério de aceite da fase, e não
> observações de estilo.
