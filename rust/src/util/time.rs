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
