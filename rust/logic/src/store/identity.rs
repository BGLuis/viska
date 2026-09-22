//! Linha singleton de identidade local dentro do banco cifrado.

use crate::crypto::identity::LocalIdentity;
use crate::{Error, Result};
use rusqlite::OptionalExtension;
use zeroize::Zeroize;

/// Carrega a identidade persistida, ou gera e persiste uma nova.
///
/// `id = 0` é o singleton — a checagem está no `CHECK` da tabela, então uma
/// segunda linha nunca chega a existir; aqui só decidimos gerar ou ler.
pub fn load_or_create(conn: &rusqlite::Connection) -> Result<LocalIdentity> {
    let existing = conn
        .query_row(
            "SELECT device_id, signing_seed, dh_secret FROM local_identity WHERE id = 0",
            [],
            |row| {
                let device_id: Vec<u8> = row.get(0)?;
                let signing_seed: Vec<u8> = row.get(1)?;
                let dh_secret: Vec<u8> = row.get(2)?;
                Ok((device_id, signing_seed, dh_secret))
            },
        )
        .optional()
        .map_err(|_| Error::Store)?;

    if let Some((device_id, signing_seed, dh_secret)) = existing {
        return Ok(LocalIdentity::from_parts(
            device_id.try_into().map_err(|_| Error::Store)?,
            signing_seed.try_into().map_err(|_| Error::Store)?,
            dh_secret.try_into().map_err(|_| Error::Store)?,
        ));
    }

    let generated = LocalIdentity::generate()?;
    let now = crate::util::time::unix_seconds() as i64;

    // Vinculados a variáveis (em vez de temporários na chamada) só para poder
    // zerar depois de gravar — o banco cifrado é um destino legítimo para
    // esses bytes, mas a cópia solta na pilha não deveria sobreviver à
    // instrução que a consumiu.
    let mut signing_seed = generated.signing_seed();
    let mut dh_secret = generated.dh().to_bytes();

    let result = conn.execute(
        "INSERT INTO local_identity (id, device_id, signing_seed, dh_secret, created_at)
         VALUES (0, ?1, ?2, ?3, ?4)",
        rusqlite::params![
            generated.device_id().as_slice(),
            signing_seed.as_slice(),
            dh_secret.as_slice(),
            now,
        ],
    );

    signing_seed.zeroize();
    dh_secret.zeroize();
    result.map_err(|_| Error::Store)?;

    Ok(generated)
}

/// Substitui a identidade armazenada pela identidade restaurada de um backup.
pub fn replace_identity(conn: &rusqlite::Connection, identity: &LocalIdentity) -> Result<()> {
    let mut signing_seed = identity.signing_seed();
    let mut dh_secret = identity.dh().to_bytes();
    let now = crate::util::time::unix_seconds() as i64;

    let result = conn.execute(
        "INSERT INTO local_identity (id, device_id, signing_seed, dh_secret, created_at)
         VALUES (0, ?1, ?2, ?3, ?4)
         ON CONFLICT(id) DO UPDATE SET
            device_id = excluded.device_id,
            signing_seed = excluded.signing_seed,
            dh_secret = excluded.dh_secret",
        rusqlite::params![
            identity.device_id().as_slice(),
            signing_seed.as_slice(),
            dh_secret.as_slice(),
            now,
        ],
    );

    signing_seed.zeroize();
    dh_secret.zeroize();
    result.map_err(|_| Error::Store)?;

    Ok(())
}

