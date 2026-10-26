#!/usr/bin/env python3
"""Run only on an explicitly named disposable emulator. Never uses a physical device."""
from pathlib import Path
import subprocess,sys,uuid
if len(sys.argv) not in [5,6]:raise SystemExit('Usage: android-smoke.py ADB PORT emulator-SERIAL APK')
adb,port,serial,apk=sys.argv[1:5]
if not serial.startswith('emulator-'):raise SystemExit('Refusing a non-emulator target')
def call(args):return subprocess.run([adb,'-P',port,'-s',serial]+args,check=True,capture_output=True,text=True).stdout
if len(sys.argv)==5:print(call(['install','-r',str(Path(apk).resolve())]))
call(['shell','am','force-stop','app.coolsync'])
call(['logcat','-b','crash','-c'])
print(call(['shell','am','start','-W','-S','-n','app.coolsync/.MainActivity']))
assert call(['shell','pidof','app.coolsync']).strip(),'Activity process died'
assert 'app.coolsync' not in call(['logcat','-d','-b','crash','-t','70']),'New crash found'
base=call(['shell','pm','path','app.coolsync']).strip().split('package:')[1]
fixture='/data/user/0/app.coolsync/files/core-check-'+uuid.uuid4().hex
print(call(['shell','run-as','app.coolsync','/system/bin/app_process','-Djava.class.path='+base,'/system/bin','app.coolsync.StorageCoreChecks',fixture,'android']))
print('Android lifecycle smoke: PASS (cold launch survives; no crash exception)')
