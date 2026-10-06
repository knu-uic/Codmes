package com.codmes.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec

internal object AppLockPin {
    fun valid(pin: String) = pin.length == 4 && pin.all { it in '0'..'9' }
    private fun derive(pin: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, 100_000, 256)
        return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
        finally { spec.clearPassword() }
    }
    fun encode(pin: String): ByteArray {
        require(valid(pin)) { "Use exactly four digits." }
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return salt + derive(pin, salt)
    }
    fun verify(pin: String, encoded: ByteArray) = valid(pin) && encoded.size == 48 &&
        MessageDigest.isEqual(encoded.copyOfRange(16, 48), derive(pin, encoded.copyOfRange(0, 16)))
}

internal class DeviceAppLock(context: Context) {
    private val preferences = context.getSharedPreferences("codmes-app-lock", Context.MODE_PRIVATE)
    private val alias = "codmes-app-lock"
    private var attempts = 0
    private var blockedUntil = 0L
    val enabled: Boolean get() = preferences.contains("pin")
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun authorize(pin: String) {
        check(android.os.SystemClock.elapsedRealtime() >= blockedUntil) { "Too many attempts. Wait one minute." }
        val valid = try {
            val data = Base64.decode(preferences.getString("pin", ""), Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
            AppLockPin.verify(pin, cipher.doFinal(data.copyOfRange(12, data.size)))
        } catch (_: Exception) { false }
        if (!valid) {
            if (++attempts >= 5) { attempts = 0; blockedUntil = android.os.SystemClock.elapsedRealtime() + 60_000 }
            error("Incorrect PIN.")
        }
        attempts = 0
    }
    fun set(current: String, pin: String, confirmation: String) {
        if (enabled) authorize(current)
        require(AppLockPin.valid(pin) && pin == confirmation) { "Enter matching four-digit PINs." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val data = cipher.iv + cipher.doFinal(AppLockPin.encode(pin))
        check(preferences.edit().putString("pin", Base64.encodeToString(data, Base64.NO_WRAP)).commit()) { "Could not save app lock." }
    }
    fun disable(current: String) {
        authorize(current)
        check(preferences.edit().remove("pin").commit()) { "Could not disable app lock." }
    }
}
