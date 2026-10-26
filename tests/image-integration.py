from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coolsync-image-')as d:
 p=Path(d);(p/'main.swift').write_text((r/'tests/image-integration.swift').read_text());subprocess.run(['javac','-d',d,str(r/'tests/FilePeer.java')],check=True);subprocess.run(['xcrun','swiftc','-swift-version','5','-D','COOLSYNC_TESTING','-module-cache-path','/tmp/coolsync-image-cache',*[str(r/'macos/Sources'/n)for n in ['CoolSync.swift','ClipHistory.swift','FileTransfer.swift']],str(p/'main.swift'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test'),d],check=True)
