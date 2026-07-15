package com.bennybar.kitzi.data.legacy

import android.content.Context
import android.util.Base64
import android.util.Log
import java.security.Key
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec

/**
 * Reads secrets the Flutter app wrote via `flutter_secure_storage` (v9, default
 * options). In practice that is exactly one value: the ABS refresh token
 * (`abs_refresh`). The server URL, access token and its expiry were kept in
 * plain SharedPreferences — see [FlutterPrefs].
 *
 * This works across the rewrite because the Kotlin app keeps the same
 * applicationId and signing key, so it runs as the same UID and can therefore
 * open the same SharedPreferences files and use the same AndroidKeyStore entry.
 *
 * The scheme (StorageCipher18Implementation):
 *   value = base64( IV(16) || AES/CBC/PKCS7( utf8(secret) ) )
 *   AES key = RSA/ECB/PKCS1-unwrapped from [AES_KEY_PREFS], using the keystore
 *   key pair under [keyAlias].
 *
 * Read-only on purpose: this is a one-way adoption of the old session. Once the
 * token has been carried over, the Kotlin app owns it and stores it itself.
 */
class FlutterSecureStorage(private val context: Context) {

    private val keyAlias = context.packageName + ".FlutterSecureStoragePluginKey"

    /** Returns the decrypted value, or null if absent or undecryptable. */
    fun read(key: String): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(ELEMENT_PREFIX + "_" + key, null) ?: return null

        // The app never passed AndroidOptions, so it should be sitting on the
        // defaults. If it somehow isn't, don't guess at the wrong cipher —
        // report nothing and let the caller fall back to a re-login.
        val keyAlgorithm = prefs.getString(ALGORITHM_KEY, DEFAULT_KEY_ALGORITHM)
        val storageAlgorithm = prefs.getString(ALGORITHM_STORAGE, DEFAULT_STORAGE_ALGORITHM)
        if (keyAlgorithm != DEFAULT_KEY_ALGORITHM || storageAlgorithm != DEFAULT_STORAGE_ALGORITHM) {
            Log.w(TAG, "Unexpected cipher ($keyAlgorithm/$storageAlgorithm); skipping token migration")
            return null
        }

        return try {
            val aesKey = unwrapAesKey() ?: return null
            val payload = Base64.decode(raw, Base64.DEFAULT)
            if (payload.size <= IV_SIZE) return null

            val iv = payload.copyOfRange(0, IV_SIZE)
            val body = payload.copyOfRange(IV_SIZE, payload.size)

            val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding")
            cipher.init(Cipher.DECRYPT_MODE, aesKey, IvParameterSpec(iv))
            String(cipher.doFinal(body), Charsets.UTF_8)
        } catch (e: Exception) {
            // A wiped keystore (device restore, some OEM backups) makes the old
            // value permanently unreadable. That costs one re-login, not data.
            Log.w(TAG, "Could not decrypt '$key' from Flutter secure storage", e)
            null
        }
    }

    private fun unwrapAesKey(): Key? {
        val wrapped = context
            .getSharedPreferences(AES_KEY_PREFS, Context.MODE_PRIVATE)
            .getString(AES_KEY_NAME, null)
            ?: return null

        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val privateKey = keyStore.getKey(keyAlias, null) ?: return null

        // AndroidKeyStoreBCWorkaround is the provider the plugin uses on M+, and
        // minSdk here is 28. A different provider fails to unwrap.
        val rsa = Cipher.getInstance("RSA/ECB/PKCS1Padding", "AndroidKeyStoreBCWorkaround")
        rsa.init(Cipher.UNWRAP_MODE, privateKey)
        return rsa.unwrap(Base64.decode(wrapped, Base64.DEFAULT), "AES", Cipher.SECRET_KEY)
    }

    companion object {
        private const val TAG = "FlutterSecureStorage"

        private const val PREFS = "FlutterSecureStorage"
        private const val AES_KEY_PREFS = "FlutterSecureKeyStorage"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val IV_SIZE = 16

        private const val ELEMENT_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
        private const val AES_KEY_NAME = "VGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"

        private const val ALGORITHM_KEY = "FlutterSecureSAlgorithmKey"
        private const val ALGORITHM_STORAGE = "FlutterSecureSAlgorithmStorage"
        private const val DEFAULT_KEY_ALGORITHM = "RSA_ECB_PKCS1Padding"
        private const val DEFAULT_STORAGE_ALGORITHM = "AES_CBC_PKCS7Padding"

        /** The only secret the Flutter app kept here. */
        const val KEY_REFRESH_TOKEN = "abs_refresh"
    }
}
