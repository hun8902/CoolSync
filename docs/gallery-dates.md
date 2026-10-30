# Gallery dates: read-only sources and verification

CoolSync formerly imported only MediaStore `datetaken`; zero/null values became unknown even when embedded capture metadata existed.

Source order:
1. Samsung `content://secmedia/media`: `_data` bound to the current page's paths, reading `datetime` and Samsung `_id`. Matching rows use Samsung's resolved date and ordering ID.
2. Existing MediaStore `datetaken` for other rows.
3. Only when that value is missing: embedded EXIF DateTimeOriginal / DateTimeDigitized, offset and subseconds, or video creation metadata. Only read streams / MediaMetadataRetriever; no EXIF saves or MediaStore updates in production code.

No modification time, import time, added date, filename-derived date, or filesystem birth-time fallback is used. File length and mtime only invalidate the in-memory metadata cache. Unavailable dates remain unknown.

## Samsung access limitation (confirmed 2026-10-30)

The locally inspected Samsung Gallery MpFilesTable chooses `datetime` on modern Android; AbsSecFilesTable orders it descending then Samsung `_id` descending. The inspected SecMediaProvider declares `com.samsung.android.providers.media.READ` with protectionLevel 3 (signatureOrSystem). A read-only empty query on the connected Galaxy returned permission denial for secmedia; querying `datetime` on the public MediaStore returned an unknown-column error. Declaring the permission does not grant it to an ordinary signed app. Access failures remain visible in Mac's loading panel and diagnostics.

Thus embedded-date recovery fixes missing source reads, but full Samsung date/order equivalence is not established and is impossible for dates stored exclusively in the protected Samsung DB without an authorized privileged integration. No such privilege changes are made by this patch.

## Checks

`SamsungDateFixtureActivity` exists only in debug builds and refuses physical devices. It checks bound provider queries, Samsung ordering IDs, missing values and denial, EXIF original date / explicit timezone / subseconds, rejects invalid dates, and compares original bytes and mtime before/after reading synthetic files. Missing EXIF never falls back to the fixture filename or mtime.

Run on an explicitly selected disposable emulator: install the debug APK, start `app.coolsync/.SamsungDateFixtureActivity`, inspect `CoolSyncDatesTest` logcat. `tests/gallery-days.py <output-dir>` checks decoding, Samsung tie order, legacy item compatibility, day boundaries and SwiftUI rendering. These are synthetic checks, not physical Galaxy gallery-equivalence proof.
