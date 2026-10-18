#!/usr/bin/env python3
"""Build the KDE source/runtime bundle from an explicit public-file allowlist."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def build(output=None):
    version = json.loads((ROOT / 'gpt-niang-usage/package.json').read_text(encoding='utf-8-sig'))['version']
    name = f'gpt-niang-kde-{version}-preview'
    output = Path(output or ROOT / 'dist')
    output.mkdir(parents=True, exist_ok=True)
    entries = {'linux.qml': ROOT / 'linux.qml', 'LICENSE': ROOT / 'LICENSE', 'README.md': ROOT / 'linux/README.md', 'VALIDATION.md': ROOT / 'linux/VALIDATION.md'}
    for relative in ['gpt-niang-usage/LICENSE', 'gpt-niang-usage/.codex-plugin/plugin.json']:
        entries[relative] = ROOT / relative
    for module in ['metadata', 'plan', 'usage', 'refresh-client', 'refresh-queue', 'worker-state', 'worker-ipc', 'watch']:
        relative = f'gpt-niang-usage/runtime/{module}.mjs'
        entries[relative] = ROOT / relative
    for asset in ['CHARACTER-NOTICE.txt', 'gpt-dragon-niang-bust.png', 'press.wav', 'release.wav', 'quotes.json', 'quotes-LICENSE.txt', '生成说明.md']:
        relative = f'gpt-niang-usage/assets/{asset}'
        entries[relative] = ROOT / relative
    # Never package state, captures, host-specific runtime paths or caches.
    for relative in ['gpt-niang', 'doctor.qml', 'README.md', 'VALIDATION.md', 'kwin/follow.js', 'runtime/cli.mjs', 'runtime/companion.mjs', 'runtime/install.mjs', 'runtime/settings.mjs', 'runtime/kwin-bridge.py', 'qml/Companion.qml', 'qml/PetWindow.qml', 'qml/SettingsWindow.qml']:
        entries['linux/' + relative] = ROOT / 'linux' / relative
    file = output / f'{name}.tar.gz'
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    with file.open('wb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=epoch) as gz, tarfile.open(fileobj=gz, mode='w') as archive:
        for relative, source in sorted(entries.items()):
            if source.is_symlink() or not source.is_file():
                raise ValueError(f'Expected regular source file: {relative}')
            data = source.read_bytes()
            info = tarfile.TarInfo(name + '/' + relative)
            info.size = len(data)
            info.mode = 0o755 if relative in ['linux/gpt-niang', 'linux/runtime/kwin-bridge.py'] else 0o644
            info.mtime = epoch
            archive.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    file.with_suffix(file.suffix + '.sha256').write_text(f'{digest}  {file.name}\n', encoding='utf-8')
    with tarfile.open(file, 'r:gz') as archive:
        assert len(archive.getmembers()) == len(entries)
        assert all(member.isfile() and member.name.startswith(name + '/') for member in archive.getmembers())
    print(f'{file}\nSHA256 {digest}\n{len(entries)} public files')
    return file


if __name__ == '__main__':
    build()
