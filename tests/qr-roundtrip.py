#!/usr/bin/env python3
# Pass the path to Maven's com.google.zxing:core:3.5.3 JAR. Test dependency only.
from pathlib import Path
import sys,tempfile,subprocess
root=Path(__file__).resolve().parents[1]
jar=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='coolsync-qr-') as d:
 p=Path(d);(p/'main.swift').write_text((root/'tests/qr-roundtrip.swift').read_text())
 sources=[str(root/'macos/Sources/QRImage.swift')]+[str(x) for x in (root/'macos/Sources/VendorQRCode').glob('*.swift')]
 subprocess.run(['xcrun','swiftc','-module-cache-path','/tmp/coolsync-qr-cache',*sources,str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'code.png')],check=True)
 subprocess.run(['javac','-cp',str(jar),'-d',d,str(root/'tests/DecodeQR.java')],check=True)
 subprocess.run(['java','-cp',str(jar)+':'+d,'DecodeQR',str(p/'code.png')],check=True)
