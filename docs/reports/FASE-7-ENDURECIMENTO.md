# Fase 7 — endurecimento do aplicativo e do dado em repouso

| Campo | Valor |
|-------|-------|
| **Status** | ❌ Não iniciada |
| **Cobertura** | ~15 % (1 de 7 tarefas) — o padding e o jitter existem no núcleo, nada no aparelho |
| **Esforço** | 5–7 dias-dev no escopo completo; 2,5–3 d no mínimo viável [modelado] |
| **Depende de** | Fases 2 a 6 — endurece o que existir; endurecer antes é endurecer o vazio |
| **Fecha requisito** | D13, o desvio que trata o adversário mais provável de todos: quem tem o aparelho na mão |

---

## 1. Estado atual — evidências

### O que existe

`wire/plaintext.rs` já preenche todo pacote até um dos dois buckets do transporte, com bytes do
CSPRNG, e `wire/jitter.rs` amostra o atraso de envio. As duas mitigações da spec §6 estão no núcleo.

### O que não existe

Nenhuma das medidas de aparelho:

```bash
grep -rn "allowBackup\|FLAG_SECURE" android/ lib/
# → 0 resultados
```

Sem `android:allowBackup="false"`, um `adb backup` carrega o banco para fora do aparelho — e o banco
ainda nem está cifrado, porque `rust/src/store/` não existe (ver Fase 2).

---

## 2. As seis decisões de design

### 2.1 Apagamento de emergência é destruição de chave, não sobrescrita de bytes

Armazenamento *flash* com *wear leveling* não garante que sobrescrever um arquivo apague os bytes
originais: o controlador escreve em outra página física. Destruir a chave mestra no KeyStore torna o
banco inteiro criptograficamente inacessível em uma operação, e é verificável.

| Opção | O que é | Custo | Veredito |
|---|---|---|---|
| Sobrescrever o arquivo | Gravar zeros sobre o banco | Lento e **não garante nada** em flash | Rejeitada |
| Apagar a chave do KeyStore | Uma chamada, efeito imediato | Irreversível por definição | **Recomendada** |

### 2.2 `FLAG_SECURE` protege a lista de recentes, não só a captura de tela

No Android, o sistema tira uma miniatura da tela ao mandar o app para segundo plano, e essa imagem
fica em disco. `FLAG_SECURE` bloqueia captura **e** miniatura. No iOS o equivalente é cobrir a tela
no `applicationWillResignActive`.

### 2.3 As chaves saem da memória quando o app vai para segundo plano

Manter o banco destravado indefinidamente anula o valor de cifrá-lo: um aparelho apreendido
desbloqueado entrega tudo. Auto-lock por inatividade, com despejo das chaves do Rust — e não apenas
uma tela de bloqueio por cima da interface, que é teatro.

### 2.4 O teclado do sistema é um canal de vazamento

Um teclado com sugestões aprende o conteúdo digitado e o guarda fora do app, às vezes sincronizado
com a nuvem do fabricante. `autocorrect: false` e `enableSuggestions: false` em todo campo de
mensagem. É uma linha de código que fecha um vazamento que nenhuma criptografia alcança.

### 2.5 Ausência de telemetria precisa ser verificada, não declarada

O `CLAUDE.md` proíbe SDK de analytics, mas proibição em documento não é controle. A verificação é
inspecionar o APK gerado e observar o tráfego de saída de uma execução real.

### 2.6 O que não fazer

**Não prometer proteção contra adversário global.** D12 já registra que jitter de 5–25 ms não
derrota correlação em múltiplos pontos, e que a conexão P2P direta expõe o IP de cada par. A UI
deve avisar no modo remoto, e a documentação deve dizer isso com todas as letras.

---

## 3. Plano de implementação

| Fase | Conteúdo | Esforço [modelado] |
|---|---|---|
| **F0** | `allowBackup=false`, auditoria de `exported`, `FLAG_SECURE`, blur no iOS | 0,5 d |
| **F1** | Bloqueio por biometria/PIN com `local_auth`, auto-lock e despejo de chaves | 1,5 d |
| **F2** | Apagamento de emergência: destruição da chave no KeyStore/Secure Enclave, com confirmação | 1 d |
| **F3** | Mensagens efêmeras com chave por mensagem e apagamento por destruição de chave | 1,5 d |
| **F4** | Varredura e descarte de `.staging` órfão na inicialização | 0,5 d |
| **F5** | Campos de texto sem autocorreção nem sugestões | 0,25 d |
| **F6** | Build reproduzível e auditoria de dependências e de tráfego de saída | 1–1,5 d |

**Mínimo viável** (o essencial de D13): F0 + F1 + F2 + F5 ≈ 3,25 d.
**Escopo completo:** F0–F6 ≈ 6,25–7,75 d.

---

## 4. Armadilhas

| Armadilha | Mitigação |
|---|---|
| StrongBox não existe em todo aparelho e a chamada falha | Degradar para KeyStore comum e **informar** o nível de proteção obtido, em vez de falhar ou fingir. |
| Biometria pode ser cadastrada por terceiro depois da instalação | Invalidar a chave quando o conjunto de biometrias mudar — o KeyStore suporta isso, e sem essa opção a proteção é contornável. |
| `FLAG_SECURE` impede screenshot legítimo do usuário | É o custo da medida. Deve ser padrão ligado, com desligamento explícito e avisado. |
| Apagamento de emergência acionado por engano é irreversível | Confirmação explícita; nunca em gesto rápido nem atrás de um toque só. |
| Build reproduzível quebra a cada atualização de dependência | Travar o `Cargo.lock` e as versões do `pubspec.lock` no repositório — que hoje não estão versionados, porque não há commits. |

---

## 5. Verificação

**Automatizável no host (`cargo test`):**

- [ ] Destruir a chave mestra torna o banco ilegível — guarda o apagamento de emergência.
- [ ] Uma mensagem efêmera expirada não é decifrável com o estado atual.

**Automatizável em CI:**

- [ ] O APK gerado não contém nenhuma classe de analytics, *crash reporting* ou publicidade — guarda
      a regra de zero telemetria por inspeção, não por declaração.
- [ ] `allowBackup` é `false` no manifesto final, depois do *merge* dos manifestos das dependências.
- [ ] Dois builds do mesmo commit produzem artefatos idênticos.

**Só em aparelho físico (não verificado até rodar):**

- [ ] `adb backup` não extrai dado útil.
- [ ] A miniatura na lista de recentes aparece em branco.
- [ ] Captura de tráfego de uma sessão completa não mostra nenhum destino inesperado.
- [ ] O app tranca sozinho depois do tempo de inatividade configurado.

---

## 6. Riscos

1. **Endurecimento feito por último costuma ser endurecimento feito pela metade.** As medidas de F0
   e F5 custam menos de um dia somadas e poderiam entrar junto com as fases que criam as telas —
   adiá-las até aqui é uma escolha de sequenciamento, não uma necessidade técnica.

2. **A ausência de telemetria depende de toda dependência futura.** Uma biblioteca acrescentada na
   Fase 6 pode trazer um SDK junto, e a verificação do APK precisa rodar em CI a cada mudança, não
   uma vez nesta fase.

3. **Build reproduzível exige disciplina de *lockfile* desde já.** Sem commits, não há *lockfile*
   versionado, e sem ele a reprodutibilidade é impossível de demonstrar.

---

## 7. Arquivos tocados

| Arquivo | Mudança |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | `allowBackup=false`, auditoria de `exported` |
| `android/app/src/main/kotlin/` | `FLAG_SECURE` na `MainActivity` |
| `ios/Runner/AppDelegate.swift` | cobertura de tela em segundo plano |
| `rust/src/store/` | apagamento de emergência, mensagens efêmeras |
| `lib/src/features/lock/` | **novo** — bloqueio, auto-lock, apagamento |
| `pubspec.yaml` | `local_auth` |
| `.github/workflows/` | inspeção do APK, verificação de reprodutibilidade |
| `docs/threat-model.md` | **novo** — o que é defendido e o que não é |

---

> Nenhum item deste relatório foi executado. Sete dos onze itens de verificação da seção 5 exigem um
> APK construído, e nenhum APK foi produzido até agora — ver a seção 7 do relatório da Fase 0.
