//! Descoberta local — `docs/protocol.md` §9 (D9).
//!
//! Só produz o `BeaconID` e o nome de instância mDNS derivados dele; não sabe
//! nada de BLE, mDNS/DNS-SD, Wi-Fi Aware ou qualquer rádio em si — isso é
//! responsabilidade da camada Dart e dos canais de plataforma (Fase 6).

pub mod beacon;

pub use beacon::{beacon_id, beacon_ids_for_window, instance_name_hex, BEACON_LEN};
