//! Codificação de inteiros e utilidades de comparação.

use subtle::ConstantTimeEq;

/// Lê um u16 big-endian de `src`, ou `None` se não houver bytes suficientes.
pub fn read_u16(src: &[u8]) -> Option<u16> {
    src.get(..2).map(|b| u16::from_be_bytes([b[0], b[1]]))
}

/// Lê um u32 big-endian de `src`.
pub fn read_u32(src: &[u8]) -> Option<u32> {
    src.get(..4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

/// Lê um u64 big-endian de `src`.
pub fn read_u64(src: &[u8]) -> Option<u64> {
    src.get(..8)
        .map(|b| u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
}

/// Lê os 5 bytes em `src` como um inteiro big-endian de 40 bits.
///
/// Usado na renderização do safety number, onde cada grupo de dígitos consome
/// exatamente 40 bits da saída XOF.
pub fn read_u40(src: &[u8; 5]) -> u64 {
    u64::from_be_bytes([0, 0, 0, src[0], src[1], src[2], src[3], src[4]])
}

/// Igualdade em tempo constante entre duas fatias.
///
/// Comparação de segredos com `==` vaza, pelo tempo de execução, a posição do
/// primeiro byte divergente.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && bool::from(a.ct_eq(b))
}
