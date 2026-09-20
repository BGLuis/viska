# Viska — instruções do projeto para agentes

> Este arquivo e `CLAUDE.md` têm conteúdo idêntico, por decisão deliberada: são regras de segurança
> e não podem depender de um salto a mais que um agente possa não dar. **Ao editar um, edite o outro.**

## O que é este projeto

Aplicativo móvel de chat e transferência de arquivos ponto a ponto **1:1**, para Android e iOS, com
criptografia híbrida pós-quântica e nenhum servidor confiável. Flutter (Dart) na interface, núcleo
Rust via `flutter_rust_bridge` para tudo que envolve segredo.

As três propriedades que o projeto existe para garantir, e que nenhuma mudança pode enfraquecer sem
decisão explícita do usuário:

1. **Nenhuma infraestrutura confiável.** Servidores STUN, brokers MQTT e pontos de acesso são todos
   tratados como hostis. A raiz de confiança é o pareamento presencial por QR Code.
2. **Resistência a "Harvest Now, Decrypt Later".** Todo segredo de sessão passa por X25519 **e**
   ML-KEM-768. Quebrar um dos dois não basta.
3. **Deniabilidade.** Nada no protocolo produz prova transferível de que uma conversa aconteceu.
   Autenticação de mensagem é sempre MAC simétrico, nunca assinatura.

## Leia isto antes de escrever qualquer código

| Arquivo | O que é |
|---|---|
| `docs/protocol.md` | **Especificação normativa.** Divergência entre código e este arquivo é bug no código. |
| `docs/deviations.md` | Por que o protocolo se afasta da especificação de arquitetura original (D1–D15), com o custo de reverter cada desvio. |
| `docs/threat-model.md` | O que é defendido, e o que explicitamente não é. |

Se for implementar uma seção do protocolo, leia a seção correspondente em `docs/protocol.md` **antes**
de escrever, não depois. Se a spec estiver ambígua ou errada, **relate** — não resolva sozinho em
silêncio, e não "conserte" um desvio de volta para a spec original sem antes ler `deviations.md`.

## Regras não negociáveis

- **Nunca enfraqueça uma primitiva para fazer um teste passar.** Se um teste criptográfico falha, ou
  o código está errado, ou o teste está errado. Trocar a primitiva, encurtar uma chave, remover uma
  validação ou relaxar uma comparação nunca é a resposta.
- **Nenhuma assinatura assimétrica por mensagem.** Ed25519 assina exatamente uma coisa neste projeto:
  o payload do QR Code. Qualquer outro uso destrói a deniabilidade e precisa de decisão do usuário.
- **Nenhum segredo cruza o FFI.** O Rust detém identidade, sessões, banco e pipeline de arquivos. O
  Dart recebe handles opacos e dados já renderizados. Chave no heap do Dart não pode ser zerada de
  forma confiável, porque o coletor de lixo move e copia objetos.
- **Aleatoriedade vem só do sistema operacional** (`crate::util::rng`, que usa `getrandom`). Nenhum
  PRNG de aplicação gera chave, nonce, padding ou jitter.
- **Nenhum segredo em `Debug`, log ou mensagem de erro.** Implemente `Debug` manualmente devolvendo
  `<redigido>` em qualquer tipo que carregue material de chave.
- **`zeroize` em todo buffer temporário** que tenha tocado chave ou plaintext.
- **Nunca reuse um par (chave, nonce).** Se um caminho de código puder repetir um contador, ele está
  errado — use XChaCha20-Poly1305 com nonce aleatório.
- **Zero telemetria.** Nada de analytics, crash reporting, anúncios, Firebase ou qualquer SDK que
  faça rede por conta própria. Uma dependência nova que abra socket é uma decisão de projeto, não de
  implementação.
- `#![forbid(unsafe_code)]` está ativo no crate. Não há exceção.

## Comandos

```bash
# Núcleo Rust (rodar de dentro de rust/)
cargo test
cargo clippy --all-targets -- -D warnings     # zero avisos é o critério
cargo build --all-features
cargo build --no-default-features             # as duas combinações têm que compilar

# Flutter (rodar da raiz)
flutter analyze
flutter test
flutter run -d <device>
```

Um teste com proptest que demore muito pode ser encurtado com `PROPTEST_CASES=64 cargo test`.

## Estrutura

```
rust/src/
  crypto/     identidade, pareamento QR, DH, KEM, handshake, ratchet, AEAD, KDF, safety number
  wire/       envelope binário, buckets de padding, tipos de pacote, enquadramento TCP, jitter
  util/       CSPRNG, épocas de rotação, codificação big-endian
lib/          Flutter: UI, transporte (WebRTC, mDNS, BLE), sinalização
android/ ios/ canais de plataforma (BLE advertise, Wi-Fi Aware, MultipeerConnectivity)
docs/         protocolo, desvios, threat model
```

**Seam de responsabilidade**, desenhado de propósito e que não deve ser borrado:
`crypto/ratchet` mexe em chaves e não serializa bytes. `wire/` mexe em bytes e não conhece chave
nenhuma. `crypto/aead` cifra. Uma camada `session` cola os três. Essa separação é o que permite
testar o `wire` exaustivamente com property tests sem precisar de nenhuma chave.

## Convenções de código

- Comentários e doc-comments em **português brasileiro**. Comentário explica **por quê**, nunca o
  quê. Se a linha é óbvia, não comente.
- Testes no próprio arquivo, em `#[cfg(test)] mod tests`, com nomes descritivos em português
  (`rejeita_tag_adulterada`, `independe_da_ordem_dos_argumentos`).
- Codec binário segue o padrão de `crypto/pairing.rs`: constantes de deslocamento nomeadas,
  `const _: () = assert!(...)` travando os tamanhos, e teste exaustivo de adulteração bit a bit.
- Toda função que processa bytes vindos da rede usa `checked_add` e `.get()` em offsets variáveis.
  Indexação direta só onde uma validação anterior no mesmo escopo garante o comprimento — e com
  comentário dizendo qual validação é essa.
- Erros de autenticação nunca distinguem a causa. Tag inválida, buffer curto e AAD errado devolvem
  todos `Error::AeadFailure`, para não abrir oráculo.

## Ambiente de desenvolvimento

- Esta máquina é **Linux**, sem Xcode. O código iOS é escrito aqui mas só compila em runner macOS no
  CI ou em um Mac. Não presuma que dá para testar iOS localmente.
- O aparelho Android conectado é um **Quest 3**. Roda o app, mas não tem acesso normal de câmera,
  então o fluxo de leitura de QR Code não pode ser validado nele. Para testar dois pares na mesma
  máquina, o alvo `linux` do Flutter existe como ferramenta de desenvolvimento — não é alvo de
  produto.
- BLE e Wi-Fi Aware só podem ser validados em hardware real.

## Ao terminar uma tarefa

Relate o que ficou fora do escopo, o que te pareceu errado na especificação e qualquer decisão de
projeto que você tomou sozinho. Um relatório que só diz "pronto" obriga a refazer a revisão do zero.
