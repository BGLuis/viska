package app.viska.viska

import android.app.Activity
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// Plugin de segurança de plataforma (Fase 7, D13).
///
/// Responsável por:
/// 1. Controle dinâmico do `FLAG_SECURE` na janela da Activity (captura de tela
///    e miniatura na lista de apps recentes).
/// 2. Gestão do segredo mestre embrulhado no Android KeyStore com hardware
///    backing (StrongBox com fallback para TEE), entregue diretamente à
///    memória nativa do Rust via JNI sem transitar pelo heap gerenciado do Dart.
class SecurityPlugin private constructor(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL_NAME = "app.viska/security"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "viska_master_key_wrap"
        private const val GCM_IV_LEN = 12
        private const val GCM_TAG_LEN_BITS = 128
        private const val MASTER_KEY_LEN = 32

        init {
            // Carrega a biblioteca nativa gerada pelo rust_builder/cargokit
            try {
                System.loadLibrary("viska_core")
            } catch (e: UnsatisfiedLinkError) {
                // Em testes ou ambientes sem a lib nativa carregada antecipadamente
            }
        }

        // Ponte JNI para memória segura do Rust — nenhum byte passa pelo Dart.
        @JvmStatic
        private external fun viska_native_set_master_secret(secret: ByteArray): Boolean

        @JvmStatic
        private external fun viska_native_clear_master_secret(): Boolean

        fun register(messenger: BinaryMessenger, activity: Activity) {
            val channel = MethodChannel(messenger, CHANNEL_NAME)
            val instance = SecurityPlugin(activity)
            channel.setMethodCallHandler(instance)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setFlagSecure" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                setFlagSecure(enabled)
                result.success(null)
            }
            "isFlagSecure" -> {
                result.success(isFlagSecure())
            }
            "initMasterSecret" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Caminho do arquivo não fornecido", null)
                    return
                }
                val success = initMasterSecret(File(path))
                result.success(success)
            }
            "destroyMasterSecret" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Caminho do arquivo não fornecido", null)
                    return
                }
                val success = destroyMasterSecret(File(path))
                result.success(success)
            }
            else -> result.notImplemented()
        }
    }

    private fun setFlagSecure(enabled: Boolean) {
        activity.runOnUiThread {
            if (enabled) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    private fun isFlagSecure(): Boolean {
        val flags = activity.window.attributes.flags
        return (flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
    }

    /// Carrega ou cria a chave mestra embrulhada no KeyStore e a injeta no Rust via JNI.
    @Synchronized
    private fun initMasterSecret(encFile: File): Boolean {
        return try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val secretKey = getOrCreateKeyStoreKey(keyStore)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val rawSecret = ByteArray(MASTER_KEY_LEN)

            if (!encFile.exists() || encFile.length() == 0L) {
                // Primeira execução: gera 32 bytes do CSPRNG do sistema
                SecureRandom().nextBytes(rawSecret)

                cipher.init(Cipher.ENCRYPT_MODE, secretKey)
                val iv = cipher.iv
                val ciphertext = cipher.doFinal(rawSecret)

                // Grava IV + ciphertext no arquivo privado
                encFile.parentFile?.mkdirs()
                FileOutputStream(encFile).use { fos ->
                    fos.write(iv)
                    fos.write(ciphertext)
                }

                // Injeta diretamente na memória do Rust
                try {
                    viska_native_set_master_secret(rawSecret)
                } catch (e: UnsatisfiedLinkError) {
                    // Ignora caso a lib nativa ainda não esteja vinculada via JNI
                }

                // Zera imediatamente o array no heap Java
                Arrays.fill(rawSecret, 0.toByte())
                true
            } else {
                // Leitura do IV + ciphertext existente
                val totalBytes = encFile.readBytes()
                if (totalBytes.size < GCM_IV_LEN + 16) {
                    return false
                }

                val iv = totalBytes.copyOfRange(0, GCM_IV_LEN)
                val ciphertext = totalBytes.copyOfRange(GCM_IV_LEN, totalBytes.size)

                val spec = GCMParameterSpec(GCM_TAG_LEN_BITS, iv)
                cipher.init(Cipher.DECRYPT_MODE, secretKey, spec)
                val decrypted = cipher.doFinal(ciphertext)

                if (decrypted.size != MASTER_KEY_LEN) {
                    Arrays.fill(decrypted, 0.toByte())
                    return false
                }

                System.arraycopy(decrypted, 0, rawSecret, 0, MASTER_KEY_LEN)
                Arrays.fill(decrypted, 0.toByte())

                try {
                    viska_native_set_master_secret(rawSecret)
                } catch (e: UnsatisfiedLinkError) {
                    // Ignora caso a lib nativa ainda não esteja vinculada via JNI
                }

                Arrays.fill(rawSecret, 0.toByte())
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    /// Apaga o alias no KeyStore, limpa a chave no Rust e deleta o arquivo cifrado.
    @Synchronized
    private fun destroyMasterSecret(encFile: File): Boolean {
        return try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(KEY_ALIAS)) {
                keyStore.deleteEntry(KEY_ALIAS)
            }
            if (encFile.exists()) {
                encFile.delete()
            }
            try {
                viska_native_clear_master_secret()
            } catch (e: UnsatisfiedLinkError) {
                // Ignora se lib não carregada
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun getOrCreateKeyStoreKey(keyStore: KeyStore): SecretKey {
        if (keyStore.containsAlias(KEY_ALIAS)) {
            val entry = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
            if (entry != null) {
                return entry.secretKey
            }
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE
        )

        val purposes = KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT

        // Tenta StrongBox primeiro se suportado pela API 28+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val strongBoxSpec = KeyGenParameterSpec.Builder(KEY_ALIAS, purposes)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setIsStrongBoxBacked(true)
                    .build()
                keyGenerator.init(strongBoxSpec)
                return keyGenerator.generateKey()
            } catch (e: Exception) {
                // Degradação documentada para KeyStore TEE padrão
            }
        }

        val standardSpec = KeyGenParameterSpec.Builder(KEY_ALIAS, purposes)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        keyGenerator.init(standardSpec)
        return keyGenerator.generateKey()
    }
}
