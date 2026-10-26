package app.coolsync

import android.app.Activity
import android.content.ClipboardManager
import android.os.*

class CaptureActivity : Activity() {
    companion object { var inFlight = false; private set }
    private val handler = Handler(Looper.getMainLooper())
    private var read = false
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if(inFlight || (SyncService.active?.authenticated != true && !ClipHistory.enabled(this))) { finish(); return }
        inFlight = true
        window.setLayout(1,1)
        handler.postDelayed({ finish() },1200) // Safety timeout, not a polling timer.
    }
    override fun onWindowFocusChanged(focus: Boolean) {
        super.onWindowFocusChanged(focus)
        if(!focus || read) return
        read = true
        window.decorView.post { capture() }
    }
    private fun capture() {
        try {
            val sync = SyncService.active
            if(getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked) return
            val clipboard = getSystemService(ClipboardManager::class.java)
            val desc = clipboard.primaryClipDescription ?: return
            // Reject old clipboard after a false-positive menu dismissal.
            val eventAt = intent.getLongExtra("eventTime",0)
            if(desc.timestamp <= 0 || desc.timestamp < eventAt-1200 || System.currentTimeMillis()-desc.timestamp > 4000) return
            if(desc.extras?.getBoolean("android.content.extra.IS_SENSITIVE",false) == true) return
            val clip = clipboard.primaryClip ?: return
            if(clip.itemCount > 0){val item=clip.getItemAt(0);val uri=item.uri
                if(uri!=null && uri.authority!="$packageName.clipboard" && contentResolver.getType(uri)?.startsWith("image/")==true){
                    if(sync?.authenticated==true)sync.localImage(uri)
                    else {val file=ClipHistory.normalized(this,uri);try{ClipHistory.image(this,file,"휴대폰")}finally{file.delete()}}
                } else item.text?.toString()?.let { if(sync?.authenticated==true)sync.localCopy(it)else ClipHistory.text(this,it,"휴대폰") }
            }
        } catch (_: Exception) { /* No content logging. */ }
        finally { finish() }
    }
    override fun finish() {
        super.finish()
        if(Build.VERSION.SDK_INT >= 34) overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE,0,0)
        else { @Suppress("DEPRECATION") overridePendingTransition(0,0) }
    }
    override fun onDestroy() { handler.removeCallbacksAndMessages(null); inFlight = false; super.onDestroy() }
}
