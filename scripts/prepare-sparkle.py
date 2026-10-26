#!/usr/bin/env python3
from pathlib import Path
import hashlib,urllib.request,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
out=root/'macos/Vendor/Sparkle'
if (out/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework').exists():raise SystemExit(0)
url='https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-for-Swift-Package-Manager.zip'
sha='3a5d7fd698acc39c122e75764ed3614b472b284cc483f32ae7006d86c513370c'
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'sparkle.zip';urllib.request.urlretrieve(url,p)
 if hashlib.sha256(p.read_bytes()).hexdigest()!=sha:raise SystemExit('Sparkle archive checksum mismatch')
 out.mkdir(parents=True,exist_ok=True);subprocess.run(['ditto','-x','-k',str(p),str(out)],check=True)
