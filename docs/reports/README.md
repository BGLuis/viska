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
| 1 | [Núcleo criptográfico](FASE-1-NUCLEO-CRIPTOGRAFICO.md) | C | ✅ Concluído | — |
| 2 | [Pareamento por QR](FASE-2-PAREAMENTO-QR.md) | C | ✅ Concluído | — |
| 3 | [Transporte remoto e chat](FASE-3-TRANSPORTE-REMOTO-E-CHAT.md) | C | ✅ Concluído | — |
| 4 | [Pipeline de arquivos](FASE-4-PIPELINE-DE-ARQUIVOS.md) | C | ✅ Concluído | — |
| 5 | [Notas de voz](FASE-5-NOTAS-DE-VOZ.md) | C | ✅ Concluído | — |
| 6 | [Rádios locais](FASE-6-RADIOS-LOCAIS.md) | C | ⚠️ Concluído (pendente validação em hardware) | — |
| 7 | [Endurecimento](FASE-7-ENDURECIMENTO.md) | C | ✅ Concluído | — |
| 8 | [Habilitação do iOS](FASE-8-HABILITACAO-IOS.md) | C | ✅ Concluída | — |
| 9 | [Evolução de UX e Segurança Avançada](FASE-9-EVOLUCAO-UX-E-SEGURANCA-AVANCADA.md) | C | ✅ Concluído | — |

Todos os módulos planejados foram implementados e cobertos por testes unitários e de integração.

## Itens que atravessam as fases

1. **Repositório versionado.** O histórico de commits está estruturado no Git, garantindo rastreabilidade, controle de versão e builds reproduzíveis com `Cargo.lock`.

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
