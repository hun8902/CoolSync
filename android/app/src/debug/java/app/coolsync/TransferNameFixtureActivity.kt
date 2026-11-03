package app.coolsync

class TransferNameFixtureActivity:android.app.Activity(){
 override fun onCreate(state:android.os.Bundle?){super.onCreate(state)
  check(android.os.Build.FINGERPRINT.contains("generic")||android.os.Build.MODEL.contains("sdk_gphone")){"Emulator only"}
  val text=android.widget.TextView(this);setContentView(text)
  val parent="Download/CoolSync-transfer-check-"+java.util.UUID.randomUUID()
  val folder=java.io.File(android.os.Environment.getExternalStorageDirectory(),parent)
  try{
   check(folder.mkdirs());val nfd=java.text.Normalizer.normalize("가나다무",java.text.Normalizer.Form.NFD)
   val upload=StorageBridge.prepareUpload(this,parent,nfd+".txt");upload.temporary.writeText("new synthetic bytes");StorageBridge.commitUpload(this,upload)
   check(upload.final.name=="가나다무.txt"&&upload.final.readText()=="new synthetic bytes"&&!upload.temporary.exists())
   check(runCatching{StorageBridge.prepareUpload(this,parent,nfd+".txt")}.isFailure)
   val pending=StorageBridge.prepareUpload(this,parent,"기존.txt")
   pending.temporary.writeText("must not overwrite")
   val existing=java.io.File(folder,java.text.Normalizer.normalize("기존.txt",java.text.Normalizer.Form.NFD));existing.writeText("existing sentinel")
   check(runCatching{StorageBridge.commitUpload(this,pending)}.isFailure);check(existing.readText()=="existing sentinel"&&pending.temporary.exists())
   check(runCatching{StorageBridge.prepareUpload(this,parent,"가".repeat(86))}.isFailure)
   text.text="PASS: Android shared-storage NFC commit, duplicate and late canonical collision rejected, existing bytes preserved, UTF-8 length rejected"
   android.util.Log.i("CoolSyncNamesTest",text.text.toString())
  }catch(e:Throwable){text.text="FAIL: "+e.toString();android.util.Log.e("CoolSyncNamesTest","FAIL",e)}finally{folder.deleteRecursively()}
 }
}
