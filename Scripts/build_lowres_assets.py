#!/usr/bin/env python3
"""Build a deduplicated 1080p, 8-bit media tree from local tvOS assets.

This script never downloads Apple media. It accepts an already available
LocalAssets directory, preserves metadata/HEIC transition frames and makes a
silent 8-bit HEVC tree capped at 1920x1080. Ordinary FFmpeg/libx265 cannot
preserve Apple's auxiliary HEVC alpha channel, so this Linux-friendly stage
must be followed on macOS by Scripts/preserve_alpha_movies.sh. That native
stage restores Apple 1080p alpha movies or downsizes 4K-only alpha movies with
AVFoundation. The FFmpeg stage is intentionally resumable because the full
catalog takes time to encode.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AssetSource:
    directory: Path
    availability: str
    priority: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="LocalAssets directory")
    parser.add_argument("output", type=Path, help="normalized output root")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", "ffmpeg"))
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--crf", type=int, default=24)
    parser.add_argument("--preset", default="medium")
    parser.add_argument("--max-width", type=int, default=1920)
    parser.add_argument("--max-height", type=int, default=1080)
    parser.add_argument(
        "--force", action="store_true", help="re-encode already valid outputs"
    )
    return parser.parse_args()


def source_packages(source: Path) -> list[AssetSource]:
    packages: list[AssetSource] = []
    for priority, name in enumerate(("DefaultAssetBundle", "DefaultAssetBundleV2"), 1):
        directory = source / name
        if directory.is_dir():
            packages.append(AssetSource(directory, "__yearRound", priority))
    expanded = source / "OptionalDownloads" / "expanded"
    if expanded.is_dir():
        for package in sorted(path for path in expanded.iterdir() if path.is_dir()):
            packages.append(AssetSource(package, package.name, 100))
    return packages


def resolve_assets(
    packages: list[AssetSource],
) -> tuple[dict[str, AssetSource], dict[str, set[str]]]:
    preferred: dict[str, AssetSource] = {}
    availability: dict[str, set[str]] = defaultdict(set)
    for package in packages:
        for asset in sorted(package.directory.glob("*.icasset")):
            identifier = asset.stem
            availability[identifier].add(package.availability)
            current = preferred.get(identifier)
            if current is None or (package.priority, str(asset)) >= (
                current.priority,
                str(current.directory),
            ):
                preferred[identifier] = AssetSource(
                    asset, package.availability, package.priority
                )
    return preferred, availability


def probe_video(ffprobe: str, path: Path) -> dict[str, object] | None:
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,pix_fmt,width,height",
        "-of",
        "json",
        str(path),
    ]
    try:
        result = subprocess.run(
            command, check=True, capture_output=True, text=True, timeout=60
        )
        streams = json.loads(result.stdout).get("streams", [])
        return streams[0] if streams else None
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def valid_output(ffprobe: str, path: Path, max_width: int, max_height: int) -> bool:
    if not path.is_file() or path.stat().st_size == 0:
        return False
    stream = probe_video(ffprobe, path)
    if not stream:
        return False
    return (
        stream.get("codec_name") == "hevc"
        and stream.get("pix_fmt") == "yuv420p"
        and int(stream.get("width", 0)) <= max_width
        and int(stream.get("height", 0)) <= max_height
    )


def convert_video(
    source: Path,
    destination: Path,
    args: argparse.Namespace,
) -> tuple[Path, int, int, float]:
    if (
        not args.force
        and destination.exists()
        and destination.stat().st_mtime_ns >= source.stat().st_mtime_ns
        and valid_output(args.ffprobe, destination, args.max_width, args.max_height)
    ):
        return destination, source.stat().st_size, destination.stat().st_size, 0.0

    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.stem}-", suffix=".mov", dir=destination.parent
    )
    os.close(fd)
    temporary = Path(temporary_name)
    started = time.monotonic()
    scale = (
        f"scale='min({args.max_width},iw)':'min({args.max_height},ih)':"
        "force_original_aspect_ratio=decrease:force_divisible_by=2"
    )
    command = [
        args.ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-map",
        "0:v:0",
        "-map_metadata",
        "-1",
        "-map_chapters",
        "-1",
        "-an",
        "-vf",
        scale,
        "-c:v",
        "libx265",
        "-preset",
        args.preset,
        "-crf",
        str(args.crf),
        "-pix_fmt",
        "yuv420p",
        "-tag:v",
        "hvc1",
        "-threads",
        "2",
        "-x265-params",
        "pools=2:frame-threads=2:log-level=error",
        "-movflags",
        "+faststart",
        "-write_tmcd",
        "0",
        str(temporary),
    ]
    try:
        subprocess.run(command, check=True)
        if not valid_output(
            args.ffprobe, temporary, args.max_width, args.max_height
        ):
            raise RuntimeError(f"invalid transcoded output: {temporary}")
        os.replace(temporary, destination)
        shutil.copystat(source, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return (
        destination,
        source.stat().st_size,
        destination.stat().st_size,
        time.monotonic() - started,
    )


def copy_metadata_and_frames(source: Path, destination: Path) -> list[tuple[Path, Path]]:
    videos: list[tuple[Path, Path]] = []
    destination.mkdir(parents=True, exist_ok=True)
    source_names = {entry.name for entry in source.iterdir()}
    for stale in destination.iterdir():
        if stale.name in source_names:
            continue
        if stale.is_dir() and not stale.is_symlink():
            shutil.rmtree(stale)
        else:
            stale.unlink()
    for entry in source.iterdir():
        target = destination / entry.name
        if entry.is_dir():
            if target.exists() and not target.is_dir():
                target.unlink()
            target.mkdir(parents=True, exist_ok=True)
            nested = copy_metadata_and_frames(entry, target)
            videos.extend(nested)
        elif entry.suffix.lower() == ".mov":
            videos.append((entry, target))
        else:
            if (
                not target.exists()
                or target.stat().st_size != entry.stat().st_size
                or target.stat().st_mtime_ns < entry.stat().st_mtime_ns
            ):
                shutil.copy2(entry, target)
    return videos


def copy_shared_resources(source: Path, output: Path) -> None:
    optional = source / "optional-assets.json"
    if optional.is_file():
        shutil.copy2(optional, output / optional.name)
    halftone = source / "FrameworkResources" / "halftone_pattern.png"
    if halftone.is_file():
        shutil.copy2(halftone, output / halftone.name)


def write_availability(output: Path, references: dict[str, set[str]]) -> None:
    root = output / "Assets" / "Availability"
    if root.exists():
        shutil.rmtree(root)
    for identifier, packages in references.items():
        for package in sorted(packages):
            directory = root / package
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"{identifier}.assetref").touch()


def main() -> int:
    args = parse_args()
    source = args.source.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if output == source or output == Path("/") or output == Path.home():
        raise SystemExit(f"refusing unsafe output directory: {output}")
    packages = source_packages(source)
    if not packages:
        raise SystemExit(f"no asset packages found under {source}")
    preferred, references = resolve_assets(packages)
    if not preferred:
        raise SystemExit("no .icasset directories found")

    resolved = output / "Assets" / "Resolved"
    resolved.mkdir(parents=True, exist_ok=True)
    selected_names = {f"{identifier}.icasset" for identifier in preferred}
    for stale in resolved.glob("*.icasset"):
        if stale.name not in selected_names:
            shutil.rmtree(stale)

    jobs: list[tuple[Path, Path]] = []
    for identifier, selected in sorted(preferred.items()):
        destination = resolved / f"{identifier}.icasset"
        jobs.extend(copy_metadata_and_frames(selected.directory, destination))
    write_availability(output, references)
    copy_shared_resources(source, output)

    original_bytes = 0
    output_bytes = 0
    converted = 0
    started = time.monotonic()
    workers = max(1, min(args.jobs, 4))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(convert_video, source_path, destination, args)
            for source_path, destination in jobs
        ]
        for future in concurrent.futures.as_completed(futures):
            path, before, after, seconds = future.result()
            original_bytes += before
            output_bytes += after
            converted += 1
            print(
                f"[{converted:3d}/{len(jobs):3d}] {path.name}: "
                f"{before / 1_048_576:.1f} -> {after / 1_048_576:.1f} MiB "
                f"({seconds:.1f}s)",
                flush=True,
            )

    summary = {
        "schemaVersion": 1,
        "assetCount": len(preferred),
        "videoCount": len(jobs),
        "codec": "hevc",
        "pixelFormat": "yuv420p",
        "maximumResolution": f"{args.max_width}x{args.max_height}",
        "crf": args.crf,
        "preset": args.preset,
        "alphaPostprocess": "Scripts/preserve_alpha_movies.sh",
        "sourceVideoBytes": original_bytes,
        "outputVideoBytes": output_bytes,
        "elapsedSeconds": round(time.monotonic() - started, 3),
    }
    (output / "lowres-build.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
