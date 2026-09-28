# Política de segurança

O Viska existe para proteger conversas contra infraestrutura hostil, contra quem grava o tráfego
hoje para decifrar amanhã e contra quem tem o aparelho na mão. Uma falha de segurança publicada antes
da correção entrega o ataque pronto. Por isso, **nunca relate uma vulnerabilidade em issue pública,
discussão ou pull request.**

## Como relatar

Use o relato privado do GitHub:
**[Relatar uma vulnerabilidade](https://github.com/BGLuis/viska/security/advisories/new)**.

Inclua, se puder:

- o que o atacante consegue (ler, forjar, rastrear, negar serviço) e o que ele precisa ter;
- o local no código (`arquivo:linha`) e o commit;
- passos de reprodução ou prova de conceito;
- a seção de `docs/protocol.md` ou o desvio de `docs/deviations.md` afetado.

Nunca envie chaves privadas, bancos de dados, payloads de pareamento ou mensagens reais de
terceiros — um cenário sintético basta.

## O que conta como vulnerabilidade

Qualquer coisa que enfraqueça as três propriedades do projeto: nenhuma infraestrutura confiável,
resistência a "Harvest Now, Decrypt Later" e deniabilidade. Também: segredo fora do núcleo Rust,
material de chave em log ou erro, reuso de par (chave, nonce), dado sensível recuperável depois do
apagamento de emergência, e contorno do bloqueio do aplicativo.

Não conta — está declarado em `docs/threat-model.md` §3: o IP real exposto numa conexão P2P direta,
correlação por um observador global, volume e frequência de tráfego, NAT simétrico sem relay.

## Versões suportadas

O projeto está em pré-lançamento (`0.1.x`). Correções entram no branch `developer` e são publicadas a
partir do `main`; não há versões anteriores mantidas.

## Divulgação

O relato vira um *security advisory* privado. A divulgação pública acontece depois que a correção
estiver no `main`, com crédito a quem relatou, se desejar.
