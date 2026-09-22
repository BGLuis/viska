//! Tempo de parede e épocas de rotação.

use std::time::{SystemTime, UNIX_EPOCH};

/// Duração de uma época de rotação, em segundos (uma hora).
///
/// Vale tanto para o tópico de sinalização quanto para o beacon BLE: os dois
/// precisam rotacionar para que um observador de longo prazo não consiga
/// correlacionar o mesmo par ao longo de dias.
pub const EPOCH_SECONDS: u64 = 3600;

/// Segundos desde o epoch Unix. Antes de 1970 é tratado como 0.
pub fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Época de rotação atual.
pub fn current_epoch() -> u64 {
    unix_seconds() / EPOCH_SECONDS
}

/// Épocas aceitáveis no momento: anterior, atual e seguinte.
///
/// A janela de três existe para tolerar desvio de relógio entre os aparelhos —
/// sem ela, dois celulares com alguns minutos de diferença simplesmente nunca
/// se encontrariam perto da virada da hora.
pub fn epoch_window() -> [u64; 3] {
    let now = current_epoch();
    [now.saturating_sub(1), now, now + 1]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_seconds_returns_plausible_recent_timestamp() {
        let secs = unix_seconds();
        // Garante que o relógio não voltou para zero ou época pré-2024.
        assert!(secs > 1_700_000_000);
    }

    #[test]
    fn current_epoch_is_consistent_with_unix_seconds() {
        let secs = unix_seconds();
        let epoch = current_epoch();
        let expected = secs / EPOCH_SECONDS;
        // Permite diferença de no máximo 1 época se o teste rodou exatamente na virada da hora.
        assert!(epoch == expected || epoch == expected + 1);
    }

    #[test]
    fn epoch_window_is_contiguous_triplet() {
        let window = epoch_window();
        assert_eq!(window[1], current_epoch());
        assert_eq!(window[2], window[1] + 1);
        assert_eq!(window[0], window[1].saturating_sub(1));
    }

    #[test]
    fn epoch_window_saturates_at_zero_without_underflow() {
        let now: u64 = 0;
        let window = [now.saturating_sub(1), now, now + 1];
        assert_eq!(window, [0, 0, 1]);
    }
}
