#!/usr/bin/env python3
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coolsync-file-test-') as d:
 p=Path(d)
 subprocess.run(['javac','-d',d,str(root/'tests/FilePeer.java')],check=True)
 (p/'main.swift').write_text((root/'tests/file-integration.swift').read_text())
 subprocess.run(['xcrun','swiftc','-swift-version','5','-D','COOLSYNC_TESTING','-module-cache-path','/tmp/coolsync-file-test-cache',str(root/'macos/Sources/CoolSync.swift'),str(root/'macos/Sources/ClipHistory.swift'),str(root/'macos/Sources/FileTransfer.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),d],check=True)
