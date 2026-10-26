#!/usr/bin/env python3
"""Create signed Android metadata and a Sparkle appcast from completed release assets."""
from pathlib import Path
import argparse,base64,hashlib,json,subprocess,xml.etree.ElementTree as ET
p=argparse.ArgumentParser();p.add_argument('--build',required=True,type=int);p.add_argument('--version',default='0.3.0');p.add_argument('--directory',type=Path,required=True);p.add_argument('--android-key',type=Path,required=True);p.add_argument('--sparkle-key',type=Path,required=True);a=p.parse_args()
out=a.directory;tag=f'build-{a.build}';base=f'https://github.com/hun8902/CoolSync/releases/download/{tag}'
apk=out/'CoolSync-android.apk';mac=out/'CoolSync-mac-arm64.zip'
m={'package':'app.coolsync','build':a.build,'version':a.version,'minSdk':31,'size':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'url':base+'/'+apk.name}
manifest=out/'android-update.json';manifest.write_text(json.dumps(m,ensure_ascii=False,separators=(',',':'))+'\n')
sig=subprocess.check_output(['openssl','dgst','-sha256','-sign',str(a.android_key),str(manifest)])
(out/'android-update.json.sig').write_text(base64.b64encode(sig).decode()+'\n')
root=Path(__file__).resolve().parents[1]
signature=subprocess.check_output(['xcrun','swift','-module-cache-path','/tmp/coolsync-sign-cache',str(root/'scripts/sparkle-key.swift'),'sign',str(a.sparkle_key),str(mac)],text=True).strip()
ns='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',ns)
rss=ET.Element('rss',{'version':'2.0'});ch=ET.SubElement(rss,'channel');ET.SubElement(ch,'title').text='CoolSync';item=ET.SubElement(ch,'item')
ET.SubElement(item,'title').text='CoolSync '+a.version
ET.SubElement(item,'{'+ns+'}version').text=str(a.build);ET.SubElement(item,'{'+ns+'}shortVersionString').text=a.version;ET.SubElement(item,'{'+ns+'}minimumSystemVersion').text='13.0.0'
ET.SubElement(item,'enclosure',{'url':base+'/'+mac.name,'length':str(mac.stat().st_size),'type':'application/octet-stream','{'+ns+'}edSignature':signature})
ET.ElementTree(rss).write(out/'appcast.xml',encoding='utf-8',xml_declaration=True)
(out/'SHA256.txt').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in sorted(out.iterdir()) if f.is_file() and f.name!='SHA256.txt'))
print('Signed metadata created for build',a.build)
