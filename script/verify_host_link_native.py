#!/usr/bin/env python3
"""Exercise the real agent with disposable apps; never closes the user's host."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def wait_for(predicate, label):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(label)


def main():
    built = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='niang-host-native-') as directory:
        root = Path(directory)
        source = root / 'Dummy.swift'
        source.write_text('''import AppKit
let args = CommandLine.arguments
if args.count == 3 && args[1] == "--terminate" {
    guard let pid = Int32(args[2]), NSRunningApplication(processIdentifier: pid)?.terminate() == true else { exit(1) }
} else {
    final class Delegate: NSObject, NSApplicationDelegate {
        let file = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "QAStatePath") as! String)
        func applicationDidFinishLaunching(_ note: Notification) {
            try! String(ProcessInfo.processInfo.processIdentifier).write(to: file, atomically: true, encoding: .utf8)
        }
        func applicationWillTerminate(_ note: Notification) { try? FileManager.default.removeItem(at: file) }
    }
    let app = NSApplication.shared
    let delegate = Delegate()
    app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
    withExtendedLifetime(delegate) {}
}
''')
        binary = root / 'Dummy'
        compiler = ['swiftc', '-module-cache-path', str(root / 'cache')]
        if os.environ.get('GPT_NIANG_SDK'):
            compiler += ['-sdk', os.environ['GPT_NIANG_SDK']]
        run(*compiler, str(source), '-o', str(binary))

        def make_app(name, identifier):
            app = root / (name + '.app')
            (app / 'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(binary, app / 'Contents/MacOS/Dummy')
            with (app / 'Contents/Info.plist').open('wb') as stream:
                plistlib.dump(dict(CFBundleExecutable='Dummy', CFBundleIdentifier=identifier,
                                   CFBundleName=name, CFBundlePackageType='APPL', LSUIElement=True,
                                   NSPrincipalClass='NSApplication', QAStatePath=str(root / (name + '.pid'))), stream)
            return app

        host = make_app('Host', 'io.github.t7moris.HostLinkQA.Host')
        pet = make_app('Pet', 'io.github.t7moris.HostLinkQA.Pet')
        helpers = pet / 'Contents/Helpers'
        helpers.mkdir()
        agent = helpers / 'GPTNiangHostLink'
        shutil.copy2(built / 'Contents/Helpers/GPTNiangHostLink', agent)
        for app in [host, pet]:
            run('/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app))
        prefs = root / 'preferences.json'

        def enable(value):
            prefs.write_text(json.dumps({'hostLink': {'enabled': value,
                'bundleIdentifier': 'io.github.t7moris.HostLinkQA.Host'}}))

        host_pid, pet_pid = root / 'Host.pid', root / 'Pet.pid'

        def terminate(file):
            if file.exists():
                run(str(binary), '--terminate', file.read_text())
                wait_for(lambda: not file.exists(), 'graceful app exit')

        enable(True)
        trace = (root / 'trace.log').open('w')
        process = subprocess.Popen([str(agent), '--data-dir', str(root), '--trace'],
                                   stdout=subprocess.DEVNULL, stderr=trace)
        try:
            time.sleep(0.6)
            assert process.poll() is None, 'agent remains running without host'
            assert not pet_pid.exists(), 'no pet opened while host absent'
            run('/usr/bin/open', '-g', '-n', str(host))
            wait_for(pet_pid.exists, 'host launch opens pet')
            terminate(pet_pid)
            time.sleep(1)
            assert not pet_pid.exists(), 'manual pet quit remains respected'
            terminate(host_pid)
            run('/usr/bin/open', '-g', '-n', str(host))
            wait_for(pet_pid.exists, 'next host launch reopens pet')
            terminate(host_pid)
            wait_for(lambda: not pet_pid.exists(), 'host exit closes pet gracefully')
            assert process.poll() is None, 'agent survives pet exit'
            enable(False)
            run('/usr/bin/open', '-g', '-n', str(host))
            wait_for(host_pid.exists, 'disabled host starts')
            time.sleep(1)
            assert not pet_pid.exists(), 'disabled link never opens pet'
            terminate(host_pid)
            enable(True)
            run('/usr/bin/open', '-g', '-n', str(host))
            wait_for(pet_pid.exists, 're-enabled link works')
            terminate(pet_pid)
            process.terminate(); process.wait(timeout=5)
            process = subprocess.Popen([str(agent), '--data-dir', str(root), '--trace'],
                                       stdout=subprocess.DEVNULL, stderr=trace)
            wait_for(pet_pid.exists, 'agent restart detects already-running host')
            terminate(host_pid)
            wait_for(lambda: not pet_pid.exists(), 'restart retains quit handling')
            print('Native host link: launch, quit, manual exit, disable, re-enable and agent restart passed')
        finally:
            trace.flush()
            print((root / 'trace.log').read_text())
            process.terminate()
            process.wait(timeout=5)
            for file in [pet_pid, host_pid]:
                if file.exists():
                    try:
                        os.kill(int(file.read_text()), 15)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    main()
