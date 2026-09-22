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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_u16_reads_big_endian_and_handles_boundaries() {
        assert_eq!(read_u16(&[0x12, 0x34]), Some(0x1234));
        assert_eq!(read_u16(&[0x12, 0x34, 0x56]), Some(0x1234));
        assert_eq!(read_u16(&[0x12]), None);
        assert_eq!(read_u16(&[]), None);
    }

    #[test]
    fn read_u32_reads_big_endian_and_handles_boundaries() {
        assert_eq!(read_u32(&[0x12, 0x34, 0x56, 0x78]), Some(0x12345678));
        assert_eq!(read_u32(&[0x12, 0x34, 0x56, 0x78, 0x99]), Some(0x12345678));
        assert_eq!(read_u32(&[0x12, 0x34, 0x56]), None);
        assert_eq!(read_u32(&[]), None);
    }

    #[test]
    fn read_u64_reads_big_endian_and_handles_boundaries() {
        assert_eq!(
            read_u64(&[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]),
            Some(0x0123456789abcdef)
        );
        assert_eq!(
            read_u64(&[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xff]),
            Some(0x0123456789abcdef)
        );
        assert_eq!(
            read_u64(&[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd]),
            None
        );
        assert_eq!(read_u64(&[]), None);
    }

    #[test]
    fn read_u40_assembles_40_bit_integer_correctly() {
        assert_eq!(read_u40(&[0, 0, 0, 0, 0]), 0);
        assert_eq!(
            read_u40(&[0xff, 0xff, 0xff, 0xff, 0xff]),
            0x0000_00ff_ffff_ffff
        );
        assert_eq!(read_u40(&[0x01, 0x02, 0x03, 0x04, 0x05]), 0x0102030405);
    }

    #[test]
    fn ct_eq_compares_slices_correctly() {
        assert!(ct_eq(&[], &[]));
        assert!(ct_eq(&[1, 2, 3], &[1, 2, 3]));
        assert!(!ct_eq(&[1, 2, 3], &[1, 2, 4]));
        assert!(!ct_eq(&[1, 2, 3], &[1, 2, 3, 4]));
        assert!(!ct_eq(&[1, 2, 3, 4], &[1, 2, 3]));
    }
}
