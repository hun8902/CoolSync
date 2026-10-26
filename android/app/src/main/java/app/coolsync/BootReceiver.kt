package app.coolsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if(intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED,Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val prefs = context.getSharedPreferences("sync",0)
        if(!prefs.getBoolean("enabled",false) || (intent.action==Intent.ACTION_BOOT_COMPLETED && !prefs.getBoolean("boot",true)) || Protocol.key(context) == null) return
        try { context.startForegroundService(Intent(context,SyncService::class.java)) }
        catch (_: Exception) { /* User can start from the app if the OS refuses background startup. */ }
    }
}
