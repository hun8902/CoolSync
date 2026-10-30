package app.coolsync
object MediaDateChecks {
 @JvmStatic fun main(args:Array<String>){
  // Actual problem rows, compared against the Samsung Gallery detail screen on 2026-10-30.
  check(MediaDates.display(0,1463497107)==1463497107000L) // 2016-05-17 23:58:27 KST
  check(MediaDates.display(0,1787842170)==1787842170000L) // wallpaper: 2026-08-27 23:49:30 KST
  check(MediaDates.display(1463497107123,1793275990)==1463497107123L) // Capture time takes precedence, precision retained.
  check(MediaDates.display(-1,1463497107)==1463497107000L)
  check(MediaDates.display(0,0)==0L);check(MediaDates.display(0,-1)==0L);check(MediaDates.display(0,Long.MAX_VALUE)==0L)
  val rows=listOf(32474L to MediaDates.display(0,1463497107),18742L to MediaDates.display(0,1787842170),32475L to MediaDates.display(0,1463497107))
  check(rows.sortedWith(compareByDescending<Pair<Long,Long>>{it.second}.thenByDescending{it.first}).map{it.first}==listOf(18742L,32475L,32474L))
  println("PASS: two real Samsung detail dates, capture precedence, ms/seconds units, invalid dates, newest date and ID tie order")
 }
}
