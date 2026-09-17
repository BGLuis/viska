# Relatórios técnicos — Viska

Um relatório por fase do roteiro de execução. Cada arquivo declara no cabeçalho o que foi medido e o
que é estimativa, e fecha com uma seção do que **não** foi verificado.

Dois modos, conforme o estado da fase:

- **Modo C — pós-implementação:** eixo antes × depois, números obrigatoriamente medidos.
- **Modo A — análise/proposta:** eixo o que existe × o que falta. Nada executado, e o relatório diz isso.

## Fases

| Fase | Relatório | Modo | Status | Esforço restante |
|---|---|---|---|---|
| 0 | [Scaffolding](FASE-0-SCAFFOLDING.md) | C | ✅ Concluído | — |
| 1 | [Núcleo criptográfico](FASE-1-NUCLEO-CRIPTOGRAFICO.md) | C | 🟡 Parcial — falta o banco e os KATs do FIPS 203 | ~1,5 d |
| 2 | [Pareamento por QR](FASE-2-PAREAMENTO-QR.md) | A | 🟡 Parcial — metade Rust pronta, nada de FFI nem UI | 4,5–5 d |
| 3 | [Transporte remoto e chat](FASE-3-TRANSPORTE-REMOTO-E-CHAT.md) | A | ❌ Não iniciada | 8–10,5 d |
| 4 | [Pipeline de arquivos](FASE-4-PIPELINE-DE-ARQUIVOS.md) | A | ❌ Não iniciada | 9,5–11,5 d |
| 5 | [Notas de voz](FASE-5-NOTAS-DE-VOZ.md) | A | ❌ Não iniciada | 3–4,5 d |
| 6 | [Rádios locais](FASE-6-RADIOS-LOCAIS.md) | A | ❌ Não iniciada | 11–14,5 d |
| 7 | [Endurecimento](FASE-7-ENDURECIMENTO.md) | A | ❌ Não iniciada | 6,25–7,75 d |
| 8 | [Habilitação do iOS](FASE-8-HABILITACAO-IOS.md) | A | ❌ Não iniciada | 4–6 d |

Todos os esforços das fases 2 a 8 são `[modelado]`. Total do escopo completo: **47–60 dias-dev**.

## Três itens que atravessam todas as fases

1. **Nada está versionado.** `git log` não tem nenhum commit. Sem ponto de retorno, sem *diff*
   revisável, e sem `Cargo.lock` versionado a Fase 7 não consegue demonstrar build reproduzível.

2. **Dois módulos não pertencem a nenhuma fase do roteiro original.** A fronteira FFI
   (`rust/src/ffi/`) e a camada de sessão (`rust/src/session/`) foram distribuídas implicitamente e
   somam de 3 a 4 dias não orçados. A camada de sessão é o maior item subestimado do projeto —
   concentra as decisões difíceis de papéis, reentrância e política de erro do AEAD.

3. **Nenhuma linha jamais rodou fora do host Linux.** Nenhum APK, nenhum build iOS, nenhuma
   cross-compilação do Rust. A cadeia de build das três plataformas está **declarada** desde a Fase
   0 e nunca foi **exercida**. Recomendação: habilitar CI macOS e um build Android antes da Fase 2,
   e não nas fases que levam o nome deles.

## Documentos relacionados

| Documento | Papel |
|---|---|
| [`../protocol.md`](../protocol.md) | Especificação normativa. Divergência entre código e ela é bug no código. |
| [`../deviations.md`](../deviations.md) | Os desvios D1–D13 em relação à arquitetura original, com custo de reverter cada um. |
| [`../../CLAUDE.md`](../../CLAUDE.md) | Regras de projeto para agentes. Conteúdo idêntico ao `GEMINI.md`. |
