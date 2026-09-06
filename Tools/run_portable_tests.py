#!/usr/bin/env python3
"""Run core test bodies on a CLT-only Mac, without the unavailable Testing module.

This is an explicit sequential assertion adapter, NOT the Swift Testing runner.
Original test sources remain unchanged and still run normally under Xcode.
UI/event-loop and shared-log-destructive tests are excluded and reported.
Generated Swift files are disposable build artifacts. No audio is captured.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'portable-tests'
OUT.mkdir(parents=True, exist_ok=True)
EXCLUDED = {
    'AppLoggerTests.swift', 'FloatingPanelTests.swift',
    'LiveCaptionTextViewTests.swift', 'EndToEndTests.swift',
}
pattern = re.compile(r'@Test\s+(?:@MainActor\s+)?func\s+(\w+)\(\)\s*(async\s*)?(throws\s*)?\{')
tests = []
parts = []
for path in sorted((ROOT / 'StreamTranslateTests').glob('*.swift')):
    if path.name in EXCLUDED:
        print('SKIP FILE (UI/shared-log):', path.name, flush=True)
        continue
    source = path.read_text()
    found = list(pattern.finditer(source))
    if len(found) != len(re.findall(r'@Test\b', source)):
        raise RuntimeError(f'Unsupported test syntax in {path.name}; refuse to skip silently')
    tests += [(m[1], bool(m[2]), bool(m[3])) for m in found]
    converted = source.replace('import Testing\n', '\n').replace('@Test ', '').replace('@Test\n', '\n')
    converted = converted.replace('@testable import StreamTranslate\n', '\n')
    converted = converted.replace('#expect(', 'portableExpect(')
    if '#require' in converted or '@Suite' in converted:
        raise RuntimeError(f'Unsupported macro in {path.name}')
    parts.append(f'#sourceLocation(file: "{path}", line: 1)\n{converted}\n#sourceLocation()\n')
(OUT / 'ConvertedTests.swift').write_text('\n'.join(parts))

calls = []
for name, asynchronous, throwing in tests:
    invocation = ('try ' if throwing else '') + ('await ' if asynchronous else '') + name + '()'
    if throwing:
        invocation = f'do {{ {invocation} }} catch {{ Issue.record("{name}: \\(error)") }}'
    calls.append(f'print("RUN {name}"); {invocation}')
runner = '''import Foundation
import AppKit

enum PortableResult {
    static let lock = NSLock()
    nonisolated(unsafe) static var failures = 0
    static func fail(_ text: String) {
        lock.withLock { failures += 1; print("FAIL " + text) }
    }
}
func portableExpect(_ condition: Bool, _ message: String? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
    if !condition { PortableResult.fail("\\(file):\\(line) \\(message ?? "expectation failed")") }
}
enum Issue {
    static func record(_ message: String) { PortableResult.fail(message) }
}
@main enum PortableRunner {
    @MainActor static func main() async {
        _ = NSApplication.shared
        CALLS
        print("PORTABLE SUMMARY: COUNT test bodies, \\(PortableResult.failures) failed assertions")
        exit(PortableResult.failures == 0 ? 0 : 1)
    }
}
'''.replace('CALLS', '\n        '.join(calls)).replace('COUNT', str(len(tests)))
(OUT / 'Runner.swift').write_text(runner)
subprocess.run(['swift','build','-c','release','--product','StreamTranslate','--disable-build-manifest-caching','--jobs','4'],cwd=ROOT,check=True)
bin_dir = Path(subprocess.check_output(['swift','build','-c','release','--show-bin-path'],cwd=ROOT,text=True).strip())
objects = [p for target in ['WhisperKit','ArgmaxCore','NemotronBridge', 'CompanionKit',
                           'X509', 'SwiftASN1', '_CertificateInternals', 'Crypto',
                           'CryptoExtras', '_CryptoExtras', 'CryptoBoringWrapper',
                           'CCryptoBoringSSL', 'CCryptoBoringSSLShims']
           for p in (bin_dir / (target+'.build')).rglob('*.o')]
# Release WMO may place shared definitions in the App's object file, so do not
# try to relink by removing that object. Recompile unchanged production sources
# with just the SwiftUI entry-point annotation removed in a generated copy.
app_entry = ROOT/'StreamTranslate'/'StreamTranslateApp.swift'
(OUT/'AppWithoutEntry.swift').write_text(app_entry.read_text().replace('@main\n', '', 1))
sources = [p for p in (ROOT/'StreamTranslate').rglob('*.swift') if p != app_entry]
command = ['swiftc','-O','-whole-module-optimization','-parse-as-library','-swift-version','6','-D','SWIFT_PACKAGE',
           '-module-name','StreamTranslate','-target','arm64-apple-macosx26.0',
           '-I',str(bin_dir/'Modules'),'-I',str(bin_dir/'NemotronBridge.build'),
           *map(str,sources),str(OUT/'AppWithoutEntry.swift'),
           str(OUT/'ConvertedTests.swift'),str(OUT/'Runner.swift'),
           *map(str,objects),'-lc++','-o',str(OUT/'StreamTranslateChecks')]
subprocess.run(command,cwd=ROOT,check=True)
subprocess.run([str(OUT/'StreamTranslateChecks')],cwd=ROOT,check=True)
