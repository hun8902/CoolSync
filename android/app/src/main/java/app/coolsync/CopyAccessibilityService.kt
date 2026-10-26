package app.coolsync

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent

// Only three event types; no node traversal, text-change subscription, polling, or READ_LOGS.
class CopyAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var scheduled: Runnable? = null
    private var lastTrigger = 0L
    private var toolbarSeenAt = 0L
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        val sync = SyncService.active ?: return
        if(!sync.authenticated || sync.locked() || CaptureActivity.inFlight) return
        if(event.packageName?.toString() == packageName) return
        val now = SystemClock.elapsedRealtime()
        val labels = event.text.map { it.toString().trim().lowercase() } + listOfNotNull(event.contentDescription?.toString()?.trim()?.lowercase())
        val copyLabels = setOf("copy","copy text","복사","텍스트 복사","コピー","复制","複製")
        val confirmation = labels.any { it.contains("copied") || it.contains("복사됨") || it.contains("복사되었습니다") || it.contains("복사했") || it.contains("클립보드에 복사") || it.contains("コピーしました") || it.contains("已复制") }
        var detected = when(event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> labels.any { it in copyLabels || it.startsWith("copy to ") }
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> confirmation
            else -> false
        }
        if(event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            if(labels.any { it in copyLabels }) { toolbarSeenAt = now; return }
            // Closing a selection menu is only a hint: CaptureActivity verifies fresh metadata.
            if(toolbarSeenAt > 0 && now-toolbarSeenAt < 5000) { detected = true; toolbarSeenAt = 0 }
            if(confirmation) detected = true
        }
        if(!detected || now-lastTrigger < 1000) return
        lastTrigger = now
        scheduled?.let(handler::removeCallbacks)
        val expectedAt = System.currentTimeMillis()
        scheduled = Runnable {
            if(SyncService.active?.authenticated != true || sync.locked()) return@Runnable
            try {
                startActivity(Intent(this,CaptureActivity::class.java).putExtra("eventTime",expectedAt).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS))
            } catch (_: Exception) { /* OEM may block the focus acquisition. Never loop. */ }
        }.also { handler.postDelayed(it,200) } // One-shot settling delay after an actual copy event.
    }
    override fun onInterrupt() { scheduled?.let(handler::removeCallbacks) }
    override fun onDestroy() { handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
