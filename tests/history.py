from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coolsync-history-')as d:
 p=Path(d);(p/'main.swift').write_text((r/'tests/history.swift').read_text());subprocess.run(['xcrun','swiftc','-module-cache-path','/tmp/coolsync-history-cache',str(r/'macos/Sources/ClipHistory.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test'),str(p/'data')],check=True)
