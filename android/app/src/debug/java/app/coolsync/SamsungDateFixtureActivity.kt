package app.coolsync
class SamsungDateFixtureActivity:android.app.Activity(){
 override fun onCreate(state:android.os.Bundle?){super.onCreate(state)
  check(android.os.Build.FINGERPRINT.contains("generic")||android.os.Build.MODEL.contains("sdk_gphone")){"Emulator only"}
  val text=android.widget.TextView(this);setContentView(text)
  try{SamsungDateChecks.main(arrayOf(java.io.File(cacheDir,"date-check-fixture").path));text.text="PASS: Samsung dates, EXIF timezone and unchanged original";android.util.Log.i("CoolSyncDatesTest",text.text.toString())}
  catch(e:Throwable){text.text="FAIL: "+e.toString();android.util.Log.e("CoolSyncDatesTest","FAIL",e)}
 }
}
