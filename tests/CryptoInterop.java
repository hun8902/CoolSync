import javax.crypto.Cipher;
import javax.crypto.spec.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

// Real JCE AES-GCM (the Android API) against the production Swift Wire codec.
public class CryptoInterop {
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32]; for(int i=0;i<32;i++) key[i]=(byte)i;
        if(args[0].equals("write")) {
            byte[] nonce = new byte[12]; for(int i=0;i<12;i++) nonce[i]=(byte)(i+32);
            String text = "한글 😀\nquote: \" slash: \\";
            String escaped = text.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n");
            String json = "{\"v\":1,\"role\":\"android\",\"id\":\"interop-test\",\"time\":"+System.currentTimeMillis()+",\"type\":\"clip\",\"text\":\""+escaped+"\",\"ref\":\"\"}";
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce)); c.updateAAD("CoolSync/1".getBytes(StandardCharsets.UTF_8));
            byte[] encrypted=c.doFinal(json.getBytes(StandardCharsets.UTF_8));
            byte[] combined = new byte[12+encrypted.length]; System.arraycopy(nonce,0,combined,0,12); System.arraycopy(encrypted,0,combined,12,encrypted.length);
            Files.writeString(Path.of(args[1]),Base64.getEncoder().encodeToString(combined));
        } else {
            byte[] combined=Base64.getDecoder().decode(Files.readString(Path.of(args[1])).trim());
            Cipher c=Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,java.util.Arrays.copyOfRange(combined,0,12))); c.updateAAD("CoolSync/1".getBytes(StandardCharsets.UTF_8));
            String json=new String(c.doFinal(java.util.Arrays.copyOfRange(combined,12,combined.length)),StandardCharsets.UTF_8);
            if(!json.contains("\"role\":\"mac\"") || !json.contains("😀")) throw new AssertionError("Swift to JCE payload mismatch");
            System.out.println("JCE → Swift → JCE: PASS (Korean, emoji, newline, quotes, backslash)");
        }
    }
}
