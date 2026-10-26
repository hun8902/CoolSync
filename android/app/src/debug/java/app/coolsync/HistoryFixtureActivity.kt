package app.coolsync
import android.app.Activity
import android.os.Bundle
import android.graphics.Bitmap
import android.content.*
import android.widget.TextView
import java.io.File
class HistoryFixtureActivity:Activity(){
 private var ran=false
 override fun onCreate(s:Bundle?){super.onCreate(s);require(android.os.Build.FINGERPRINT.contains("generic")||android.os.Build.MODEL.contains("sdk_gphone")){"Test emulator only"};setContentView(TextView(this).apply{text="Synthetic clipboard test"})}
 override fun onWindowFocusChanged(f:Boolean){super.onWindowFocusChanged(f);if(!f||ran)return;ran=true;window.decorView.postDelayed({runChecks()},200)}
 private fun runChecks(){try{
  require(ClipHistory.entries(this).isEmpty()){ "Refusing nonempty history" }
  ClipHistory.text(this,"one","test");val id=ClipHistory.entries(this)[0].getString("id");ClipHistory.favorite(this,id);ClipHistory.text(this,"one","test");check(ClipHistory.entries(this).size==1&&ClipHistory.entries(this)[0].getBoolean("favorite"))
  for(i in 0..210)ClipHistory.text(this,"item-$i","test");check(ClipHistory.entries(this).size==200&&ClipHistory.entries(this).any{it.optString("text")=="one"&&it.optBoolean("favorite")});ClipHistory.clear(this)
  val file=File(cacheDir,"fixture.png");val bitmap=Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888);bitmap.eraseColor(0xff007aff.toInt());file.outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)};bitmap.recycle()
  ClipHistory.image(this,file,"test");val image=ClipHistory.entries(this)[0];ClipHistory.copy(this,image);val clip=getSystemService(android.content.ClipboardManager::class.java).primaryClip!!;check(clip.getItemAt(0).uri!=null);check(contentResolver.getType(clip.getItemAt(0).uri!!)=="image/png");contentResolver.openInputStream(clip.getItemAt(0).uri!!)!!.use{check(it.read()==137)}
  val saved=ClipHistory.file(this,image);ClipHistory.remove(this,image.getString("id"));check(!saved.exists());contentResolver.openInputStream(clip.getItemAt(0).uri!!)!!.use{check(it.read()==137)}
  ClipHistory.text(this,"회의 일정은 오후 3시입니다.","Mac");ClipHistory.text(this,"https://github.com/hun8902/CoolSync","휴대폰");ClipHistory.image(this,file,"Mac");ClipHistory.favorite(this,ClipHistory.entries(this).last().getString("id"));file.delete()
  android.util.Log.i("CoolSyncHistoryTest","PASS: bound, favorites, dedup, image MIME/provider, clipboard survives history delete")
  startActivity(Intent(this,MainActivity::class.java));finish()
 }catch(e:Exception){android.util.Log.e("CoolSyncHistoryTest","FAIL",e);setContentView(TextView(this).apply{text="Test failed: "+e.javaClass.simpleName})}}
}
