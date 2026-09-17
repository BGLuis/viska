# Fase 4 — pipeline de arquivos com Merkle BLAKE3 e RaptorQ

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada |
| **Cobertura** | ~10 % (1 de 6 tarefas) — só o AEAD de símbolo e os tipos de pacote existem |
| **Esforço** | 8–11 dias-dev no escopo completo; 5–6,5 d no mínimo viável [modelado] |
| **Depende de** | Fase 3 completa — sem canal não confiável negociado, o RaptorQ não tem onde pagar por si |
| **Atenção** | É a fase com maior risco de consumo de memória, e a que mais depende de teste em hardware real |

---

## 1. Estado atual — evidências

### O que existe

`crypto/aead.rs` expõe `seal_xchacha`/`open_xchacha`, a cifra correta para símbolo de arquivo
segundo D11 — nonce de 24 B sorteado e prefixado, porque transferência retomável não tem contador
confiável. Os tipos de pacote da spec §6.2 já estão declarados em `wire/packet_type.rs`:
`FILE_METADATA`, `FILE_SYMBOL`, `FILE_FEEDBACK`, `FILE_COMPLETE`.

### O que não existe

Nem o módulo, nem a dependência:

```bash
ls rust/src/file
# → No such file or directory

grep -n "raptorq" rust/Cargo.toml
# → 0 resultados
```

`blake3` está em `rust/Cargo.toml:15`, mas nenhum código usa a árvore de Merkle interna dele — só
`derive_key` e `keyed_hash`, em `crypto/kdf.rs`.

---

## 2. As cinco decisões de design

### 2.1 Um source block por vez em RAM, e o tamanho do bloco é o que decide

O decodificador RaptorQ precisa do *source block* inteiro em memória. Esta é a razão pela qual D6
fixa 1.024 símbolos por bloco: com símbolo de 16 KB no DataChannel, cada bloco ocupa ~16 MB.

| Símbolos por bloco | RAM por bloco a 16 KB | Veredito |
|---|---|---|
| 8.192 | ~128 MB | Rejeitada: derruba o app em aparelho de gama baixa |
| 1.024 | ~16 MB | **Recomendada** |
| 256 | ~4 MB | Rejeitada: overhead de cabeçalho por bloco cresce sem ganho real |

A promessa da spec §5.3 — "nenhum arquivo é montado na memória volátil" — é sobre o **arquivo**,
não sobre o bloco. Um bloco tem que caber, e o relatório de execução precisa medir o pico real.

### 2.2 RaptorQ só no canal não confiável

D6. Na LAN TCP o canal já é confiável e o RaptorQ é desligado, dando lugar a transferência por
offset com retomada. Ou seja: **dois caminhos de código distintos**, não um parametrizado.

### 2.3 Feedback esparso é obrigatório, não opcional

O desenho original pedia zero ACK. Sem nenhum retorno, o emissor não sabe quando parar de gerar
reparo nem a que taxa transmitir — e um emissor sem controle de congestionamento em rede móvel
derruba a própria conexão. O `FILE_FEEDBACK` a cada ~500 ms informa contagem por bloco, que é
volume, dado que o observador já enxerga.

### 2.4 O staging é cifrado, e abortar destrói a chave

Spec §7.5. Sobrescrever bytes em armazenamento com *wear leveling* não garante apagamento; destruir
`K_staging` torna o resíduo criptograficamente inacessível. É mais barato e mais confiável.

### 2.5 O que não fazer

**Não verificar a Merkle root só no fim.** A árvore interna do BLAKE3 permite verificar cada bloco
assim que ele é decodificado. Deixar tudo para o final significa descobrir corrupção depois de
gravar 500 MB, e não ter como saber qual bloco falhou.

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | `rust/src/file/merkle.rs`: raiz BLAKE3 e verificação incremental por bloco | 1,5 d |
| **F1** | `rust/src/file/manifest.rs`: `FILE_METADATA` em CBOR, nome do arquivo cifrado no corpo | 0,5 d |
| **F2** | `rust/src/file/fountain.rs`: RaptorQ por source block, emissor e decodificador | 2–3 d |
| **F3** | `rust/src/file/staging.rs`: gravação cifrada por página de 64 KB, commit atômico, destruição da chave no abort | 1,5–2 d |
| **F4** | Controle de taxa e `FILE_FEEDBACK` na camada `session` | 1,5 d |
| **F5** | Caminho alternativo por offset para a LAN TCP | 1 d |
| **F6** | UI de progresso, retomada e cancelamento | 1,5–2 d |

**Mínimo viável** (arquivo grande transferido e verificado no DataChannel): F0–F4 ≈ 7–8,5 d.
**Escopo completo:** F0–F6 ≈ 9,5–11,5 d.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| Símbolo de 64 KB não passa de forma interoperável no DataChannel | D5: 16 KB no WebRTC, 64 KB só na LAN. `wire/transport.rs` já impõe isso. |
| `seal_xchacha` prefixa o nonce com `splice(0..0, ..)`, que é um memmove do buffer inteiro | No caminho quente dos símbolos, reservar 24 B de folga no início do buffer em vez de deslocar. |
| RFC 6330 limita a 56.403 símbolos-fonte por bloco | D6 já fixa 1.024; travar em `const` com `assert!`, não em comentário. |
| Retomada depois de troca de transporte muda o tamanho do símbolo | O `file_id` e a Merkle root sobrevivem; o particionamento em blocos, não. Reiniciar o bloco em curso, nunca o arquivo. |
| `.staging` sobrevive a *crash* e vaza espaço em disco | Varredura na inicialização, apagando *staging* sem transferência ativa correspondente. |

---

## 5. Verificação

**Automatizável no host (`cargo test`):**

- [ ] Ida e volta de um arquivo de 100 MB em `tempfile`, com 30 % dos símbolos descartados
      aleatoriamente — guarda que o RaptorQ realmente repara, e não só que compila.
- [ ] Merkle root recomputada bate com a do manifesto; um bloco corrompido é detectado **no bloco**,
      não no fim.
- [ ] Abortar a transferência torna o `.staging` indecifrável — guarda a destruição da chave.
- [ ] Pico de RSS durante a decodificação fica abaixo de 64 MB — o invariante de D6.

**Só em aparelho físico (não verificado até rodar):**

- [ ] Arquivo de 500 MB com o Wi-Fi derrubado no meio e restaurado.
- [ ] Transferência iniciada na LAN e migrada para WebRTC sem perder progresso.
- [ ] Consumo de memória e térmico em aparelho de gama baixa.

---

## 6. Riscos

1. **O pico de memória é o risco número um desta fase.** A promessa de não montar arquivo em RAM
   depende inteiramente do tamanho do source block, e o número só se confirma medindo.

2. **`raptorq` 2.0 é uma dependência de terceiros no caminho de dados.** Não faz parte do núcleo
   criptográfico, mas um *bug* de decodificação corrompe arquivo em silêncio — daí a Merkle root
   ser verificada de forma independente, e não como formalidade.

3. **Dois caminhos de código para transferência dobram a superfície de teste.** RaptorQ no WebRTC e
   offset na LAN precisam ser testados separadamente, e a migração entre eles é o caso mais difícil.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/src/file/{mod,merkle,manifest,fountain,staging}.rs` | **novo** |
| `rust/Cargo.toml` | `raptorq`, e uma crate de CBOR para o manifesto |
| `rust/src/session/` | controle de taxa, `FILE_FEEDBACK` |
| `rust/src/ffi/transfer.rs` | **novo** — progresso e cancelamento |
| `lib/src/features/files/` | **novo** — seleção, progresso, retomada |
| `docs/protocol.md` | §7 revisado se o particionamento em blocos mudar |

---

> Nenhum item deste relatório foi executado. Os números de memória são `[modelado]` a partir do
> tamanho de símbolo e da contagem de símbolos por bloco, e não de medição — a medição está listada
> na seção 5 como pendente.
