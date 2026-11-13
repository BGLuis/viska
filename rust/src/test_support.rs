//! Atalhos dos testes sobre `Core::receive_incoming`.
//!
//! Os testes antigos falam em "alimentar o handshake" e "decifrar um
//! envelope"; o app só tem a entrada única, que decide sozinha o que os bytes
//! são (`docs/protocol.md` §11.4). Fica fora de `ffi/` para o codegen não
//! expor estes nomes ao Dart.

use crate::ffi::core::Core;
use crate::ffi::error::FfiError;
use crate::ffi::types::IncomingMessageDto;

impl Core {
    /// A resposta que o Rust manda de volta ao par para `bytes`.
    pub(crate) fn feed_handshake(
        &self,
        peer_device_id: Vec<u8>,
        bytes: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, FfiError> {
        Ok(self.receive_incoming(peer_device_id, bytes)?.reply)
    }

    /// A mensagem decifrada de `envelope`, descartando qualquer resposta.
    pub(crate) fn decrypt_incoming(
        &self,
        peer_device_id: Vec<u8>,
        envelope: Vec<u8>,
    ) -> Result<Option<IncomingMessageDto>, FfiError> {
        Ok(self.receive_incoming(peer_device_id, envelope)?.message)
    }
}
