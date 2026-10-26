#!/usr/bin/env python3
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[1]
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
locations=['org.jetbrains.kotlin/kotlin-compiler-embeddable/2.3.0','org.jetbrains.kotlin/kotlin-stdlib/2.3.0','org.jetbrains.kotlin/kotlin-script-runtime','org.jetbrains.kotlin/kotlin-reflect','org.jetbrains.kotlin/kotlin-daemon-embeddable/2.3.0','org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2','org.jetbrains/annotations/13.0']
jars=[str(p)for location in locations for p in (cache/location).rglob('*.jar')if not any(x in p.name for x in ['-sources','-javadoc'])]
stdlib=next(str(p)for p in (cache/'org.jetbrains.kotlin/kotlin-stdlib/2.3.0').rglob('*.jar')if '-sources'not in p.name)
with tempfile.TemporaryDirectory(prefix='coolsync-storage-')as d:
 out=Path(d)/'classes';out.mkdir()
 subprocess.run(['java','-cp',':'.join(jars),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',stdlib,'-d',str(out),str(root/'android/app/src/main/java/app/coolsync/StorageEngine.kt'),str(root/'android/app/src/debug/java/app/coolsync/StorageCoreChecks.kt')],check=True)
 subprocess.run(['java','-cp',str(out)+':'+stdlib,'app.coolsync.StorageCoreChecks',str(Path(d)/'fixture')],check=True)
