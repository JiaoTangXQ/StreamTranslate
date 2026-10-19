#!/usr/bin/env python3
"""Compile an in-module Swift replay tool against production sources on CLT."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def build_tool(entry: Path, output: Path):
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swift','build','-c','release','--product','StreamTranslate','--jobs','4'],
                   cwd=ROOT, check=True)
    bin_dir = Path(subprocess.check_output(['swift','build','-c','release','--show-bin-path'],
                                         cwd=ROOT,text=True).strip())
    app = ROOT/'StreamTranslate'/'StreamTranslateApp.swift'
    generated = output.parent/'AppWithoutEntry.swift'
    generated.write_text(app.read_text().replace('@main\n', '', 1))
    sources = [p for p in (ROOT/'StreamTranslate').rglob('*.swift') if p != app]
    objects = [p for target in ['WhisperKit','ArgmaxCore','NemotronBridge','CompanionKit',
                               'X509','SwiftASN1','_CertificateInternals','Crypto',
                               'CryptoExtras','_CryptoExtras','CryptoBoringWrapper',
                               'CCryptoBoringSSL','CCryptoBoringSSLShims']
               for p in (bin_dir/(target+'.build')).rglob('*.o')]
    subprocess.run(['swiftc','-O','-whole-module-optimization','-parse-as-library','-swift-version','6',
                    '-D','SWIFT_PACKAGE','-module-name','StreamTranslate',
                    '-target','arm64-apple-macosx26.0',
                    '-I',str(bin_dir/'Modules'),'-I',str(bin_dir/'NemotronBridge.build'),
                    *map(str,sources),str(generated),str(entry),*map(str,objects),
                    '-lc++','-o',str(output)],cwd=ROOT,check=True)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: build_local_tool.py Tools/Entry.swift build/tool/Executable')
    build_tool((ROOT/sys.argv[1]).resolve(), (ROOT/sys.argv[2]).resolve())
