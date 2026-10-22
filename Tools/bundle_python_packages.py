#!/usr/bin/env python3
"""Bundle the supported packages and their transitive dependencies from the pinned Pyodide release."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / 'Strata/Resources/PyRuntime/pyodide'
VERSION = re.search(r'static let version = "([^"]+)"', (ROOT / 'Strata/Tools/Python/PyodideServer.swift').read_text())[1]
BASE = f'https://cdn.jsdelivr.net/pyodide/v{VERSION}/full/'
lock = json.loads((RUNTIME / 'pyodide-lock.json').read_text())
selected = {}


def include(name):
    if name in selected:
        return
    package = lock['packages'][name]
    selected[name] = package
    for dependency in package.get('depends', []):
        include(dependency)


for name in ['numpy', 'pandas', 'matplotlib']:
    include(name)


def download(item):
    name, package = item
    target = RUNTIME / package['file_name']
    data = target.read_bytes() if target.exists() else urllib.request.urlopen(BASE + package['file_name'], timeout=120).read()
    if hashlib.sha256(data).hexdigest() != package['sha256']:
        raise ValueError(f'{name}: sha256 mismatch')
    target.write_bytes(data)
    return len(data)


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    sizes = list(pool.map(download, sorted(selected.items())))
# Worker verifies this dependency-closed subset against the full upstream lock; keep upstream lock untouched.
(RUNTIME / 'bundled-packages.json').write_text(json.dumps(sorted(selected), indent=2) + '\n')
print(f'{len(sizes)} wheels; {sum(sizes):,} bytes ({sum(sizes) / 1024 / 1024:.2f} MiB); all sha256 verified')
