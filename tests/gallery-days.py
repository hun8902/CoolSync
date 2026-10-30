from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coolsync-gallery-days-')as temp:
 p=Path(temp);(p/'main.swift').write_text((root/'tests/gallery-days.swift').read_text())
 sources=[str(x)for x in (root/'macos/Sources').glob('*.swift')if x.name!='main.swift']+[str(x)for x in (root/'macos/Sources/VendorQRCode').glob('*.swift')]
 f=root/'macos/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path',str(root/'macos/build/ModuleCache'),*sources,str(p/'main.swift'),'-F',str(f),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(f),'-o',str(p/'days')],check=True)
 subprocess.run([str(p/'days'),str(Path(sys.argv[1]).resolve())],check=True)
