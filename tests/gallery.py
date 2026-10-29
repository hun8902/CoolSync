from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="coolsync-gallery-") as temp:
    folder=Path(temp);(folder/"main.swift").write_text((root/"tests/gallery.swift").read_text())
    sources=[str(p) for p in (root/"macos/Sources").glob("*.swift") if p.name!="main.swift"]+[str(p) for p in (root/"macos/Sources/VendorQRCode").glob("*.swift")]
    framework=root/"macos/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    subprocess.run(["xcrun","swiftc","-swift-version","5","-module-cache-path",str(root/"macos/build/ModuleCache"),*sources,str(folder/"main.swift"),"-F",str(framework),"-framework","Sparkle","-Xlinker","-rpath","-Xlinker",str(framework),"-o",str(folder/"gallery")],check=True)
    subprocess.run([str(folder/"gallery"),str(Path(sys.argv[1]).resolve() if len(sys.argv)>1 else folder/"previews")],check=True)
