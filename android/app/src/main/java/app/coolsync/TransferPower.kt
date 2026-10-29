package app.coolsync

import android.content.Context
import android.os.PowerManager

/** Only explicit work holds the CPU; no Wi-Fi lock, screen lock, heartbeat or standby lease. */
object TransferPower {
 fun acquire(c:Context,timeoutMillis:Long=15*60*1000L):AutoCloseable {
  val lock=c.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"CoolSync:UserTransfer")
  lock.setReferenceCounted(false);lock.acquire(timeoutMillis)
  return AutoCloseable { if(lock.isHeld)lock.release() }
 }
}
