#!/usr/bin/env python3
"""Install Splash Finish's signed macOS release without sudo."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPOSITORY = "bobuk-io/splash-finish"
TEAM_ID = "S32B9D7R7D"
APP_NAME = "Splash Finish.app"
BIN_NAME = "splash-finish"
MAX_ZIP_BYTES = 120 * 1024 * 1024
MAX_UNPACKED_BYTES = 300 * 1024 * 1024


class InstallError(Exception):
    pass


def choose_bin(path: str | None = None, home: Path | None = None) -> tuple[Path, bool]:
    home = home or Path.home()
    choices = [home / ".local/bin", home / "bin", home / ".bin"]
    entries = {Path(item).expanduser() for item in (path if path is not None else os.environ.get("PATH", "")).split(os.pathsep) if item}
    return next(((d, True) for d in choices if d in entries), (choices[0], False))


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=120)


def release_assets(directory: Path, repo: str = REPOSITORY) -> tuple[Path, Path]:
    """gh handles private releases; unauthenticated urllib handles public releases."""
    gh = shutil.which("gh")
    if gh:
        result = subprocess.run([gh, "release", "download", "--repo", repo, "--dir", str(directory),
                                 "--pattern", "SplashFinish-*-universal.zip", "--pattern", "SHA256SUMS"],
                                capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            archives = list(directory.glob("SplashFinish-*-universal.zip"))
            if len(archives) == 1 and (directory / "SHA256SUMS").is_file():
                return archives[0], directory / "SHA256SUMS"
        # A partially downloaded file must not be mixed with another release.
        for path in directory.iterdir():
            if path.is_file():
                path.unlink()
    try:
        request = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers={"User-Agent": "splash-finish-installer"})
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
        assets = release["assets"]
        archives = [a for a in assets if a["name"].startswith("SplashFinish-") and a["name"].endswith("-universal.zip")]
        checksums = [a for a in assets if a["name"] == "SHA256SUMS"]
        if len(archives) != 1 or len(checksums) != 1:
            raise InstallError("The release must contain one universal ZIP and SHA256SUMS.")
        paths = []
        for asset in [archives[0], checksums[0]]:
            if asset.get("size", 0) > MAX_ZIP_BYTES:
                raise InstallError("Release asset exceeds the download limit.")
            request = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "splash-finish-installer"})
            path = directory / asset["name"]
            with urllib.request.urlopen(request, timeout=60) as response, path.open("wb") as target:
                data = response.read(MAX_ZIP_BYTES + 1)
                if len(data) > MAX_ZIP_BYTES:
                    raise InstallError("Release asset exceeds the download limit.")
                target.write(data)
            paths.append(path)
        return paths[0], paths[1]
    except (urllib.error.URLError, KeyError, ValueError) as error:
        raise InstallError("Could not download the latest release. If the repository is private, authenticate with 'gh auth login'.") from error


def verify_checksum(archive: Path, sums: Path) -> None:
    if archive.stat().st_size > MAX_ZIP_BYTES or sums.stat().st_size > 100_000:
        raise InstallError("Downloaded asset is too large.")
    matches = []
    for line in sums.read_text(encoding="utf-8").splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2 and fields[1].lstrip("*") == archive.name:
            matches.append(fields[0].lower())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if len(matches) != 1 or matches[0] != digest:
        raise InstallError("SHA-256 checksum does not match the release.")


def check_archive(archive: Path) -> None:
    total = 0
    try:
        with zipfile.ZipFile(archive) as bundle:
            links: set[str] = set()
            names: list[str] = []
            for entry in bundle.infolist():
                name = entry.filename
                path = Path(name)
                if not name.startswith(APP_NAME + "/") or path.is_absolute() or ".." in path.parts or "\\" in name:
                    raise InstallError(f"Unexpected archive entry: {name}")
                normalized = posixpath.normpath(name)
                names.append(normalized)
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    if entry.file_size > 1024:
                        raise InstallError(f"Invalid symbolic link: {name}")
                    target = bundle.read(entry).decode("utf-8", errors="strict")
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(normalized), target))
                    if target.startswith("/") or "\\" in target or not resolved.startswith(APP_NAME + "/"):
                        raise InstallError(f"Unsafe symbolic link: {name}")
                    links.add(normalized)
                total += entry.file_size
                if total > MAX_UNPACKED_BYTES:
                    raise InstallError("Unpacked application exceeds size limit.")
            for name in names:
                if any(name.startswith(link + "/") for link in links):
                    raise InstallError(f"Archive entry descends through a symbolic link: {name}")
    except (zipfile.BadZipFile, OSError, UnicodeError) as error:
        raise InstallError("Invalid application archive.") from error


def verify_signature(app: Path) -> None:
    try:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
        result = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
    except subprocess.CalledProcessError as error:
        raise InstallError(f"Application signature is invalid: {error.stderr.strip()}") from error
    details = result.stdout + result.stderr
    lines = details.splitlines()
    if f"TeamIdentifier={TEAM_ID}" not in lines or not any(line.startswith("Authority=Developer ID Application:") for line in lines):
        raise InstallError(f"The application was not signed with the expected Developer ID team ({TEAM_ID}).")


def install(archive: Path, sums: Path, app_dir: Path, bin_dir: Path) -> Path:
    verify_checksum(archive, sums)
    check_archive(archive)
    app_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    destination = app_dir / APP_NAME
    binary = bin_dir / BIN_NAME
    if destination.is_symlink():
        raise InstallError(f"Refusing to replace a symlink: {destination}")
    if binary.exists() and not binary.is_symlink():
        raise InstallError(f"Refusing to replace an existing file: {binary}")
    target = destination / "Contents/MacOS/SplashFinish"
    if binary.is_symlink() and os.readlink(binary) != str(target):
        raise InstallError(f"Refusing to replace an unrelated symlink: {binary}")
    # Extract on the same volume as the destination so replacements can be renamed atomically.
    with tempfile.TemporaryDirectory(prefix=".splash-finish-", dir=app_dir) as tmp:
        staging = Path(tmp)
        try:
            run(["/usr/bin/ditto", "-x", "-k", str(archive), str(staging)])
        except subprocess.CalledProcessError as error:
            raise InstallError(f"Could not extract application: {error.stderr.strip()}") from error
        app = staging / APP_NAME
        if not (app / "Contents/MacOS/SplashFinish").is_file():
            raise InstallError("Archive does not contain the expected application.")
        verify_signature(app)
        if destination.exists():
            verify_signature(destination)
            # Ask the running app to quit before replacing its bundle.
            subprocess.run(["/usr/bin/osascript", "-e", 'if application id "io.bobuk.splash-finish" is running then tell application id "io.bobuk.splash-finish" to quit'],
                           capture_output=True, text=True, timeout=10, check=False)
            old = staging / "old.app"
            os.rename(destination, old)
        else:
            old = None
        moved = False
        try:
            os.rename(app, destination)
            moved = True
            temporary_link = bin_dir / f".{BIN_NAME}-{os.getpid()}"
            try:
                temporary_link.symlink_to(target)
                os.replace(temporary_link, binary)
            finally:
                temporary_link.unlink(missing_ok=True)
        except BaseException:
            if moved and destination.exists():
                shutil.rmtree(destination)
            if old is not None and old.exists():
                if destination.exists():
                    backup = app_dir / f"Splash Finish.previous-{os.getpid()}.app"
                    os.rename(old, backup)
                    raise InstallError(f"Destination changed during installation. Previous app preserved at {backup}")
                os.rename(old, destination)
            raise
    subprocess.run(["/usr/bin/open", "-g", str(destination)], check=False)
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Install the latest signed Splash Finish release.")
    parser.add_argument("--app-dir", type=Path, default=Path.home() / "Applications")
    parser.add_argument("--bin-dir", type=Path, default=None)
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        print("Splash Finish requires macOS.", file=sys.stderr)
        return 1
    selected, on_path = choose_bin()
    bin_dir = args.bin_dir.expanduser() if args.bin_dir else selected
    try:
        with tempfile.TemporaryDirectory(prefix="splash-finish-download-") as tmp:
            archive, sums = release_assets(Path(tmp))
            destination = install(archive, sums, args.app_dir.expanduser(), bin_dir)
        print(f"Installed Splash Finish to {destination}")
        print(f"Command: {bin_dir / BIN_NAME}")
        if not args.bin_dir and not on_path:
            print(f'Add to PATH: export PATH="{bin_dir}:$PATH"')
        print("Next: splash-finish install-skills")
        print("Codex: open /hooks and trust the installed hooks. Pi: /reload existing sessions.")
        print("If macOS blocks the app, verify its signature and notarization before opening it.")
        return 0
    except (InstallError, OSError, subprocess.SubprocessError) as error:
        print(f"Install failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
