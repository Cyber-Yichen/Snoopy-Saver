#!/usr/bin/env python3
"""Download Snoopy media from a user-supplied CDN with SHA-256 verification."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import ssl
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", help="local path or HTTPS URL")
    parser.add_argument("--base-url", help="override manifest baseURL")
    parser.add_argument(
        "--destination",
        type=Path,
        default=Path("~/Library/Application Support/Snoopy/Assets/Resolved"),
    )
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument(
        "--allow-http", action="store_true", help="only for a trusted local smoke-test server"
    )
    return parser.parse_args()


def read_manifest(location: str, allow_http: bool) -> dict:
    parsed = urllib.parse.urlparse(location)
    if parsed.scheme in {"http", "https"}:
        if parsed.scheme != "https" and not allow_http:
            raise ValueError("manifest URL must use HTTPS")
        with urllib.request.urlopen(location, timeout=30) as response:
            return json.load(response)
    with Path(location).expanduser().open(encoding="utf-8") as stream:
        return json.load(stream)


def sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def safe_destination(root: Path, relative: str) -> Path:
    parts = Path(relative).parts
    if (
        len(parts) != 2
        or not parts[0].endswith(".icasset")
        or Path(parts[1]).suffix.lower() not in {".mov", ".heic"}
    ):
        raise ValueError(f"manifest path is not Snoopy media: {relative}")
    candidate = (root / relative).resolve()
    if candidate == root or root not in candidate.parents:
        raise ValueError(f"unsafe manifest path: {relative}")
    return candidate


def download_one(
    entry: dict, root: Path, base_url: str, retries: int, allow_http: bool
) -> tuple[str, str]:
    relative = str(entry["path"])
    expected_size = int(entry["size"])
    expected_hash = str(entry["sha256"]).lower()
    if not (0 < expected_size < 2 * 1024 * 1024 * 1024):
        raise ValueError(f"invalid media size for {relative}: {expected_size}")
    if len(expected_hash) != 64 or any(
        character not in "0123456789abcdef" for character in expected_hash
    ):
        raise ValueError(f"invalid SHA-256 for {relative}")
    destination = safe_destination(root, relative)
    if (
        destination.is_file()
        and destination.stat().st_size == expected_size
        and sha256(destination) == expected_hash
    ):
        return relative, "cached"

    url = str(entry.get("url") or "")
    if base_url:
        url = base_url.rstrip("/") + "/" + urllib.parse.quote(relative, safe="/")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" and not (allow_http and parsed.scheme == "http"):
        raise ValueError(f"media URL must use HTTPS: {url}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}-", suffix=".download", dir=destination.parent
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Snoopy-CDN/1.1"})
            with urllib.request.urlopen(
                request, timeout=120, context=ssl.create_default_context()
            ) as response, temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            if temporary.stat().st_size != expected_size:
                raise ValueError(
                    f"size mismatch for {relative}: {temporary.stat().st_size} != {expected_size}"
                )
            if sha256(temporary) != expected_hash:
                raise ValueError(f"SHA-256 mismatch for {relative}")
            os.replace(temporary, destination)
            return relative, "downloaded"
        except Exception as error:  # bounded retry, reported after final attempt
            last_error = error
            temporary.unlink(missing_ok=True)
            if attempt < retries:
                time.sleep(min(8, 2**attempt))
    assert last_error is not None
    raise last_error


def main() -> int:
    args = parse_args()
    manifest = read_manifest(args.manifest, args.allow_http)
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("files"), list):
        raise SystemExit("unsupported or malformed manifest")
    base_url = args.base_url or str(manifest.get("baseURL") or "")
    destination = args.destination.expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    completed = 0
    workers = max(1, min(args.jobs, 8))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(
                download_one,
                entry,
                destination,
                base_url,
                args.retries,
                args.allow_http,
            ): entry
            for entry in manifest["files"]
        }
        for future in concurrent.futures.as_completed(futures):
            completed += 1
            try:
                relative, status = future.result()
                print(f"[{completed}/{len(futures)}] {status}: {relative}", flush=True)
            except Exception as error:
                relative = futures[future].get("path", "<unknown>")
                failures.append(f"{relative}: {error}")
                print(f"[{completed}/{len(futures)}] failed: {relative}: {error}", file=sys.stderr)
    if failures:
        print(f"{len(failures)} download(s) failed", file=sys.stderr)
        return 1
    print(f"Verified {completed} media files in {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
