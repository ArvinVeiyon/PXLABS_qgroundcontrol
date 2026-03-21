# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for pxlabs_cli.py
# Run from E:\qgc-pxlabs\tools\: python -m PyInstaller pxlabs_cli.spec

import sys
from PyInstaller.utils.hooks import collect_submodules, collect_data_files

a = Analysis(
    ['pxlabs_cli.py'],
    pathex=[],
    binaries=[],
    datas=(
        collect_data_files('paramiko') +
        collect_data_files('cryptography')
    ),
    hiddenimports=(
        collect_submodules('paramiko') +
        collect_submodules('cryptography') +
        collect_submodules('keyring') +
        ['keyring.backends.Windows',
         'keyring.backends.fail',
         'jaraco.classes',
         'jaraco.functools',
         'jaraco.text',
         'importlib_metadata',
         'pkg_resources']
    ),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'unittest', 'logging.handlers', 'pydoc', 'doctest'],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='pxlabs_cli',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
