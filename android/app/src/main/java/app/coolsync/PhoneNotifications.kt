package app.coolsync

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/** Event-driven forwarding. No history, polling, or notification-content logging. */
class PhoneNotifications : NotificationListenerService() {
    private val recent = LinkedHashMap<String, String>()
    override fun onNotificationPosted(item: StatusBarNotification?) {
        item ?: return
        val sync = SyncService.active ?: return
        if (!getSharedPreferences("sync", 0).getBoolean("forwardNotifications", false) || !sync.authenticated || sync.locked() || item.packageName == packageName) return
        val notification = item.notification
        if (notification.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_GROUP_SUMMARY) != 0) return
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(160) ?: ""
        val text = (notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: notification.extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.take(1200) ?: ""
        if (title.isBlank() && text.isBlank()) return
        val signature = title + "\n" + text
        if (recent[item.key] == signature) return
        recent[item.key] = signature
        while (recent.size > 100) recent.remove(recent.keys.first())
        val app = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(item.packageName, 0)).toString() }.getOrDefault(item.packageName)
        sync.sendControl("phoneNotification", JSONObject().put("app", app.take(100)).put("title", title).put("body", text).toString())
    }
    override fun onNotificationRemoved(item: StatusBarNotification?) { item?.let { recent.remove(it.key) } }
    override fun onListenerDisconnected() { recent.clear() }
}
