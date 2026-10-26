#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
output=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'design/previews'
with tempfile.TemporaryDirectory(prefix='coolsync-render-')as d:
 p=Path(d);(p/'main.swift').write_text((root/'tests/render.swift').read_text())
 sources=[str(x)for x in (root/'macos/Sources').glob('*.swift')if x.name!='main.swift']+[str(x)for x in (root/'macos/Sources/VendorQRCode').glob('*.swift')]
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path','/tmp/coolsync-render-cache',*sources,str(p/'main.swift'),'-o',str(p/'snapshot')],check=True)
 subprocess.run([str(p/'snapshot'),str(output)],check=True)
