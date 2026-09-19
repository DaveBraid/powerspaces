#!/usr/bin/env python3
"""Sign bundles with a persistent local identity when configured."""
import json
import os
from pathlib import Path
import subprocess
import sys


def run(arguments):
    '''执行签名工具；失败仅输出工具诊断，避免在异常中打印钥匙串口令。'''
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)


def main():
    '''签署传入的应用包；本机身份配置存在时必须成功，禁止降级为临时签名。'''
    app = Path(sys.argv[1]).resolve()
    root = Path.home() / "Library/Application Support/Powerspaces/Signing"
    identity = os.environ.get("CODESIGN_IDENTITY")
    options = []
    if not identity and root.exists():
        config = json.loads((root / "identity.json").read_text())
        identity = config["identity"]
        keychain = config["keychain"]
        password = (root / "password").read_text()
        run(["security", "unlock-keychain", "-p", password, keychain])
        options = ["--keychain", keychain, "--timestamp=none"]
    elif not identity:
        identity = "-"  # 未配置签名的其他构建机保留上游临时签名行为。
        print("Warning: ad-hoc signing; updates can invalidate Accessibility approval.")
    if root.exists() and identity == "-":
        raise SystemExit("Local signing is configured; refusing ad-hoc identity replacement.")
    print("Signing with persistent identity" if identity != "-" else "Signing ad hoc")
    for target in [app / "Contents/Resources/powerspaces", app]:
        run(["codesign", "--force", "--sign", identity, *options, str(target)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])


if __name__ == "__main__":
    main()
