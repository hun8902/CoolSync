#!/usr/bin/env python3
"""Protocol interoperability and manifest/power invariants. No devices or app launch."""
from pathlib import Path
import subprocess, tempfile, xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
def run(*args): subprocess.run(args,check=True)
with tempfile.TemporaryDirectory(prefix='coolsync-test-') as temp:
    tmp = Path(temp)
    source = (ROOT/'macos/Sources/CoolSync.swift').read_text()
    wire = source[:source.index('enum KeyStore')]
    checks = r'''
let args = CommandLine.arguments
let key = Data((0..<32).map { UInt8($0) })
let frame = try Data(contentsOf:URL(fileURLWithPath:args[1]))
let m = try Wire.open(frame,key:key)
precondition(m.text == "한글 😀\nquote: \" slash: \\")
var altered = Data(base64Encoded:frame)!
altered[altered.count-1] ^= 1
var rejected = false
do { _ = try Wire.open(Data(altered.base64EncodedString().utf8),key:key) } catch { rejected = true }
precondition(rejected,"Tampered frame must fail authentication")
rejected = false
do { _ = try Wire.open(frame,key:Data(repeating:255,count:32)) } catch { rejected = true }
precondition(rejected,"Wrong pairing key must fail authentication")
var reply = Wire.Message(type:"clip"); reply.text = m.text
let outbound = try Wire.seal(reply,key:key)
try outbound.write(to:URL(fileURLWithPath:args[2]))
var expired = Wire.Message(type:"clip"); expired.role = "android"; expired.time -= 121000
rejected = false
do { _ = try Wire.open(Data(try Wire.seal(expired,key:key).dropLast()),key:key) } catch { rejected = true }
precondition(rejected,"Expired frame must be rejected")
var large = Wire.Message(type:"clip"); large.role = "android"; large.text = String(repeating:"\u{0000}",count:Wire.maxText)
let largeFrame = try Wire.seal(large,key:key)
precondition(largeFrame.count < Wire.maxFrame,"Escaped max-size clipboard must fit the receive buffer")
let largeDecoded = try Wire.open(Data(largeFrame.dropLast()),key:key)
precondition(largeDecoded.text == large.text)
print("Swift authentication: PASS (tampering, wrong key, expiry; maximum escaped frame round trip)")
'''
    (tmp/'main.swift').write_text(wire+checks)
    run('javac','-d',str(tmp),str(ROOT/'tests/CryptoInterop.java'))
    run('java','-cp',str(tmp),'CryptoInterop','write',str(tmp/'android.frame'))
    run('xcrun','swiftc','-module-cache-path',str(tmp/'cache'),str(tmp/'main.swift'),'-o',str(tmp/'check'))
    run(str(tmp/'check'),str(tmp/'android.frame'),str(tmp/'mac.frame'))
    run('java','-cp',str(tmp),'CryptoInterop','read',str(tmp/'mac.frame'))
ns = '{http://schemas.android.com/apk/res/android}'
manifest = ET.parse(ROOT/'android/app/src/main/AndroidManifest.xml').getroot()
permissions={p.get(ns+'name') for p in manifest.findall('uses-permission')}
assert not permissions.intersection({'android.permission.WAKE_LOCK','android.permission.READ_LOGS','android.permission.BLUETOOTH_SCAN','android.permission.ACCESS_FINE_LOCATION'})
for p in (ROOT/'android/app/src/main/java').rglob('*.kt'):
    s=p.read_text()
    assert not any(x in s for x in ['Timer(', 'scheduleAtFixedRate', 'acquireWakeLock', 'AlarmManager'])
ET.parse(ROOT/'android/app/src/main/res/xml/accessibility.xml')
ET.parse(ROOT/'android/app/src/main/res/values/strings.xml')
print('Android power/permission invariants and XML: PASS')
