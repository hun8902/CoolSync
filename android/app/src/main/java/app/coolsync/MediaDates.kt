package app.coolsync

/** Public gallery date: capture time in ms, otherwise the preserved file date in seconds. */
object MediaDates {
 fun display(taken:Long,modifiedSeconds:Long):Long = when {
  taken>0 -> taken
  modifiedSeconds>0 && modifiedSeconds<=Long.MAX_VALUE/1000 -> modifiedSeconds*1000
  else -> 0
 }
}
