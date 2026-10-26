package app.coolsync

import android.content.Context
import android.os.PowerManager

/** Only explicit work holds the CPU; standby never holds a wake lock. */
object TransferPower {
 fun acquire(c:Context):AutoCloseable {
  val lock=c.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"CoolSync:UserTransfer")
  lock.setReferenceCounted(false);lock.acquire(15*60*1000L)
  return AutoCloseable { if(lock.isHeld)lock.release() }
 }
}
