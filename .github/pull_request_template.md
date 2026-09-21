## 📋 Descrição das Alterações

<!-- Forneça um resumo claro e objetivo do que este Pull Request implementa, corrige ou refatora. -->

## 🎯 Tipo de Mudança

- [ ] 🐛 Correção de Bug (`fix`)
- [ ] ✨ Nova Funcionalidade (`feat`)
- [ ] 🛡️ Criptografia / Segurança (`security`)
- [ ] ♻️ Refatoração de Código (`refactor`)
- [ ] 📝 Documentação (`docs`)
- [ ] 🧪 Testes (`test`)
- [ ] ⚙️ Infraestrutura / CI / Chore (`chore`)

## 🔐 Checklist de Segurança e Criptografia (Obrigatório)

Em conformidade com `GEMINI.md` / `CLAUDE.md`:

- [ ] Nenhuma primitiva criptográfica foi enfraquecida para fazer testes passarem.
- [ ] Nenhum segredo ou chave privada cruza a fronteira FFI para o lado Dart.
- [ ] Nenhuma assinatura assimétrica por mensagem foi introduzida (deniabilidade preservada).
- [ ] Todo segredo temporário em memória é devidamente limpo com `zeroize`.
- [ ] Não há vazamento de chaves ou dados sensíveis em `Debug`, logs ou mensagens de erro.
- [ ] Aleatoriedade provém exclusivamente de `crate::util::rng` (CSPRNG do SO).
- [ ] O crate Rust continua compilando sem avisos sob `#![forbid(unsafe_code)]`.
- [ ] Zero dependências com telemetria, analytics ou conexões ocultas à rede foram adicionadas.

## 🧪 Validação Local Executada

- [ ] `cd rust && cargo test --workspace` (passou sem erros)
- [ ] `cd rust && cargo clippy --all-targets -- -D warnings` (zero warnings)
- [ ] `cd rust && cargo build --all-features && cargo build --no-default-features` (compilou com sucesso)
- [ ] `flutter analyze` (zero erros de análise)
- [ ] `flutter test` (todos os testes passaram)

## 🔗 Issues Relacionadas

<!-- Exemplo: Closes #123, Fixes #456 -->
