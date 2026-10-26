package app.coolsync

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Wire: base64(12-byte nonce | AES-256-GCM(JSON, AAD)) + LF. Maximum 16 KiB text.
object Protocol {
    const val SERVICE = "8d2ec100-45bd-4a5a-9fb6-11e7a189c001"
    const val RX = "8d2ec101-45bd-4a5a-9fb6-11e7a189c001"
    const val TX = "8d2ec102-45bd-4a5a-9fb6-11e7a189c001"
    const val CCC = "00002902-0000-1000-8000-00805f9b34fb"
    const val MAX_TEXT = 16384
    const val MAX_FRAME = 140000
    private val aad = "CoolSync/1".toByteArray()
    fun key(context: Context): ByteArray? {
        val hex = context.getSharedPreferences("sync", 0).getString("key", "") ?: ""
        if (!hex.matches(Regex("[0-9a-fA-F]{64}"))) return null
        return hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
    fun message(type: String, text: String = "", ref: String = ""): JSONObject = JSONObject()
        .put("v", 1).put("role", "android").put("id", UUID.randomUUID().toString())
        .put("time", System.currentTimeMillis()).put("type", type).put("text", text).put("ref", ref)
    fun seal(key: ByteArray, message: JSONObject): ByteArray {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce)); c.updateAAD(aad)
        return (Base64.encodeToString(nonce + c.doFinal(message.toString().toByteArray(StandardCharsets.UTF_8)), Base64.NO_WRAP) + "\n").toByteArray()
    }
    fun open(key: ByteArray, frame: ByteArray): JSONObject {
        val raw = Base64.decode(frame, Base64.NO_WRAP)
        require(raw.size >= 28)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, raw.copyOfRange(0,12))); c.updateAAD(aad)
        val m = JSONObject(String(c.doFinal(raw.copyOfRange(12, raw.size)), StandardCharsets.UTF_8))
        require(m.getInt("v") == 1 && m.getString("role") == "mac")
        require(kotlin.math.abs(System.currentTimeMillis() - m.getLong("time")) < 120000)
        require(m.getString("id").length <= 64)
        return m
    }
}
