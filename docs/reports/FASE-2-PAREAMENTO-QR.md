# Fase 2 — pareamento presencial por QR Code

| Campo | Valor |
|-------|-------|
| **Status** | 🟡 Parcial — a metade Rust está pronta e testada; a fronteira FFI, a persistência e toda a interface não existem |
| **Cobertura** | ~40 % (2 de 5 tarefas) |
| **Esforço** | 3,5–5 dias-dev no escopo completo; 2–2,5 d no mínimo viável [modelado] |
| **Depende de** | `rust/src/ffi/` e `rust/src/store/`, que também não existem e são pré-requisito da Fase 3 |
| **Bloqueia** | Fase 3 — sem contato pareado e persistido não há segredo compartilhado para derivar tópico de sinalização |

---

## 1. Estado atual — evidências

### O que existe

A lógica criptográfica do pareamento está completa em `rust/src/crypto/pairing.rs` (204 linhas). O
payload tem 145 bytes, travados em tempo de compilação:

```rust
// rust/src/crypto/pairing.rs:31-33
pub const QR_PAYLOAD_LEN: usize = SIGNATURE_AT + SIGNATURE_LEN;

const _: () = assert!(QR_PAYLOAD_LEN == 145);
```

`encode_qr` (`:36`) e `decode_qr` validam versão, assinatura Ed25519, auto-pareamento e chave X25519
de ordem baixa. A cobertura de testes é forte: `rejeita_qualquer_bit_adulterado` percorre os 145
bytes × 8 bits e exige que **toda** alteração de um único bit seja rejeitada — 1.160 casos.

O safety number está em `rust/src/crypto/safety_number.rs` (129 linhas), com 12 grupos de 5 dígitos
(~199 bits), contra os ~20 bits do desenho original — ver D3 em `docs/deviations.md`.

### O que não existe

Nenhuma das três peças que ligam esse código à tela:

```bash
ls rust/src/
# → crypto  lib.rs  util  wire      (sem ffi/, sem store/)

grep -n "mobile_scanner\|qr_flutter" pubspec.yaml
# → 0 resultados
```

`lib/main.dart` continua o esqueleto vazio do `flutter create`.

### ⚠️ Defeito de planejamento: a fronteira FFI não estava no recorte da fase

O roteiro original tratava a Fase 2 como "tela de QR", pressupondo que o núcleo já fosse chamável do
Dart. Não é. Tudo em `crypto/` é `pub`, mas `flutter_rust_bridge` não gera ligação para um módulo
arbitrário — ele gera para o módulo apontado por `--rust-input`, que precisa ser escrito à mão com
tipos que atravessam a fronteira.

Isso não é custo desta fase por acidente: é custo desta fase porque ela é a primeira que precisa
falar com a interface. Não é causado pelo pedido, mas está no caminho crítico dele.

---

## 2. Análise tarefa a tarefa

| Tarefa | Status | Observações |
|---|---|---|
| **T2.1** Codec do payload de 145 B | ✅ | `crypto/pairing.rs`, com teste exaustivo de adulteração bit a bit. |
| **T2.2** Safety number de 60 dígitos | ✅ | `crypto/safety_number.rs`. Falta só a renderização em palavras, prevista na spec §3.3. |
| **T2.3** Fronteira FFI (`rust/src/ffi/`) | ❌ | Não existe. Pré-requisito de tudo que vem depois. |
| **T2.4** Persistência cifrada do contato | ❌ | Nenhum `store/`, nenhum `rusqlite` em `rust/Cargo.toml`. |
| **T2.5** Telas de geração e leitura | ❌ | Nenhuma dependência de câmera ou QR no `pubspec.yaml`. |

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | `rust/src/ffi/` mínimo: gerar identidade, `gerar_qr() -> Vec<u8>`, `ler_qr(bytes) -> Contato`, `safety_number() -> String`. Regenerar as ligações com `--rust-input crate::ffi`. | 1 d |
| **F1** | `rust/src/store/`: `rusqlite` com SQLCipher, chave mestra embrulhada no KeyStore/Secure Enclave, migrations, tabelas de identidade e contato. | 1,5–2 d |
| **F2** | Tela de exibição do QR (`qr_flutter`, modo binário) e do safety number. | 0,5 d |
| **F3** | Tela de leitura (`mobile_scanner`), permissão de câmera, tratamento dos erros de `decode_qr` com mensagem útil. | 1 d |
| **F4** | Renderização do safety number em 6 palavras de uma lista de 2048, prevista na spec §3.3 e ainda não implementada. | 0,5 d |

**Mínimo viável** (dois aparelhos se pareiam e exibem o mesmo safety number): F0 + F1 + F2 + F3
≈ 4–4,5 d. **Escopo completo:** F0–F4 ≈ 4,5–5 d.

Ordem importa: F1 antes de F2 evita uma tela que pareia e esquece o contato ao fechar o app — e
retrabalho na camada de estado, que precisaria passar de memória para banco depois de pronta.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| `mobile_scanner` devolve o conteúdo como `String`; o payload é binário de 145 B e não sobrevive a UTF-8 | Ler os *raw bytes* (`barcode.rawBytes`), nunca `barcode.rawValue`. Se a API não expuser bytes de forma confiável, gerar o QR em Base64URL e aceitar o payload maior. |
| Gerar o QR em modo alfanumérico infla a matriz | Forçar modo byte no `qr_flutter`; 145 B cabem em Versão 7 com correção M. |
| Chave do banco em `flutter_secure_storage` (lado Dart) viola a regra de fronteira | A chave mestra deve ser desembrulhada **dentro** do Rust. O Dart pode segurar o *blob* embrulhado, nunca a chave em claro. |
| `decode_qr` devolve seis erros distintos e a UI colapsar tudo em "QR inválido" esconde ataque de MitM | `Error::SelfPairing` e `Error::LowOrderPoint` merecem mensagem própria — o segundo é sinal de payload forjado, não de leitura ruim. |
| Aparelho de teste é um Quest 3, sem acesso normal de câmera | Validar o fluxo óptico em telefone real ou AVD com câmera emulada. Ver seção 6 do relatório da Fase 0. |

---

## 5. Verificação

**Automatizável no host (`cargo test`):**

- [ ] `ffi`: `gerar_qr` seguido de `ler_qr` em duas identidades distintas devolve o contato correto —
      guarda o invariante de que a serialização da fronteira não corrompe o payload.
- [ ] `store`: gravar e reler um contato devolve bytes idênticos, e abrir o banco com a chave errada
      falha — guarda que a cifragem em repouso está ativa, não apenas configurada.

**Automatizável no host (`flutter test`):**

- [ ] O widget do safety number renderiza 12 grupos de 5 dígitos para uma entrada conhecida.

**Só em dois aparelhos físicos (declarar como não verificado até rodar):**

- [ ] Dois aparelhos se pareiam por leitura mútua e exibem safety numbers idênticos.
- [ ] Apontar a câmera para o próprio QR produz a mensagem de auto-pareamento, não um contato.
- [ ] O QR é lido sob iluminação irregular e a mais de 20 cm — é o que valida a escolha de manter a
      chave ML-KEM de 1.184 B fora do payload.

---

## 6. Riscos

1. **A fronteira FFI é onde a regra "nenhum segredo cruza" se ganha ou se perde.** Uma assinatura
   descuidada — devolver a identidade inteira ao Dart em vez de um handle — anula toda a higiene de
   memória do núcleo Rust, e o erro é invisível em teste.

2. **SQLCipher via `rusqlite` acrescenta compilação de C ao build de todas as plataformas.** É a
   primeira dependência nativa não-Rust do projeto, e é ela que vai revelar se a cadeia de
   cross-compilação da Fase 0 realmente funciona no Android.

3. **O payload de 145 B é um contrato de compatibilidade.** Mudá-lo depois que dois usuários se
   parearam invalida o pareamento. A versão em `:0` existe para isso, mas não há caminho de migração
   projetado — e a spec §10 rejeita *downgrade* de propósito.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `rust/src/ffi/mod.rs` · `identity.rs` · `pairing.rs` | **novo** — superfície FFI |
| `rust/src/store/mod.rs` · `schema.rs` · `contacts.rs` | **novo** — persistência cifrada |
| `rust/Cargo.toml` | `rusqlite` com feature de SQLCipher |
| `rust/src/crypto/safety_number.rs` | renderização em palavras (spec §3.3) |
| `pubspec.yaml` | `mobile_scanner`, `qr_flutter`, `permission_handler` |
| `lib/src/features/pairing/` | **novo** — telas de exibição e leitura |
| `lib/src/rust/` | **novo** — gerado por `flutter_rust_bridge_codegen` |
| `android/app/src/main/AndroidManifest.xml` · `ios/Runner/Info.plist` | permissão de câmera |

---

> Nenhum item deste relatório foi executado. A análise vem da leitura do código em *working tree*
> não versionado — não há commit a citar, conforme a seção 7 do relatório da Fase 0. A validação
> está listada na seção 5 como pendente.
