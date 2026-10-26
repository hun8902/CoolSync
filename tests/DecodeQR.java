import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;
import java.io.File;
public class DecodeQR {
 public static void main(String[] args)throws Exception{
  BufferedImage image=ImageIO.read(new File(args[0]));int w=image.getWidth(),h=image.getHeight();byte[] data=new byte[w*h];
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){int rgb=image.getRGB(x,y);data[y*w+x]=(byte)((((rgb>>16)&255)*299+((rgb>>8)&255)*587+(rgb&255)*114)/1000);}
  LuminanceSource source=new LuminanceSource(w,h){public byte[] getMatrix(){return data;}public byte[] getRow(int y,byte[] row){if(row==null||row.length<w)row=new byte[w];System.arraycopy(data,y*w,row,0,w);return row;}};
  String result=new QRCodeReader().decode(new BinaryBitmap(new HybridBinarizer(source))).getText();
  String expected="coolsync://pair?key="+"a".repeat(64)+"&name=CoolSync%20Mac";
  if(!result.equals(expected))throw new AssertionError("QR payload mismatch");
  System.out.println("QR round trip: PASS (production bitmap encoder → independent ZXing decoder; URI and key intact)");
 }
}
