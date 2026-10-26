#!/usr/bin/env python3
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coolsync-rpc-')as d:
 p=Path(d);(p/'main.swift').write_text((root/'tests/explorer-rpc.swift').read_text())
 sources=[str(root/'macos/Sources'/x)for x in ['CoolSync.swift','FileTransfer.swift','Explorer.swift']]
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path','/tmp/coolsync-rpc-cache',*sources,str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
