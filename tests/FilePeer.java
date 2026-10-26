import javax.crypto.*;
import javax.crypto.spec.*;
import java.net.*;
import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
public class FilePeer {
 static byte[] key=new byte[32]; static { for(int i=0;i<32;i++) key[i]=(byte)i; }
 static byte[] crypt(boolean encrypt,byte[] bytes,String aad) throws Exception {
  byte[] nonce=encrypt?new byte[12]:Arrays.copyOfRange(bytes,0,12);if(encrypt)new SecureRandom().nextBytes(nonce);
  Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(encrypt?1:2,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce));c.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
  byte[] result=c.doFinal(encrypt?bytes:Arrays.copyOfRange(bytes,12,bytes.length));
  if(!encrypt)return result;byte[] out=Arrays.copyOf(nonce,12+result.length);System.arraycopy(result,0,out,12,result.length);return out;
 }
 static byte[] wire(String type,String text,String id) throws Exception {
  String json="{\"v\":1,\"role\":\"android\",\"id\":\""+UUID.randomUUID()+"\",\"time\":"+System.currentTimeMillis()+",\"type\":\""+type+"\",\"text\":\""+text+"\",\"ref\":\""+id+"\"}";
  return Base64.getEncoder().encode(crypt(true,json.getBytes(StandardCharsets.UTF_8),"CoolSync/1"));
 }
 static void write(DataOutputStream o,byte[] b)throws Exception{o.writeInt(b.length);o.write(b);o.flush();}
 static byte[] read(DataInputStream i)throws Exception{int n=i.readInt();if(n<=0||n>100000)throw new Exception("bad frame");byte[] b=new byte[n];i.readFully(b);return b;}
 static String open(byte[] data)throws Exception{return new String(crypt(false,Base64.getDecoder().decode(data),"CoolSync/1"),StandardCharsets.UTF_8);}
 public static void main(String[] a)throws Exception {
  String flow=a[0],id=a[3],token=a[4];long size=Long.parseLong(a[5]);
  try(Socket socket=new Socket("127.0.0.1",Integer.parseInt(a[1]))){socket.setSoTimeout(10000);DataInputStream in=new DataInputStream(new BufferedInputStream(socket.getInputStream()));DataOutputStream out=new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));write(out,wire("fileAuth",token,id));if(!open(read(in)).contains("fileStart"))throw new Exception("start");
   if(flow.equals("upload")){try(InputStream f=Files.newInputStream(Path.of(a[2]))){byte[] b=new byte[65536];int n,index=0;while((n=f.read(b))>=0)write(out,crypt(true,Arrays.copyOf(b,n),"CoolSync/file/1|"+id+"|"+index++));}if(!open(read(in)).contains("fileDone"))throw new Exception("ack");}
   else {try(OutputStream f=Files.newOutputStream(Path.of(a[2]))){long count=0;int index=0;while(count<size){byte[] b=crypt(false,read(in),"CoolSync/file/1|"+id+"|"+index++);count+=b.length;if(count>size)throw new Exception("overflow");f.write(b);}}write(out,wire("fileDone","",id));}
  }
 }
}
