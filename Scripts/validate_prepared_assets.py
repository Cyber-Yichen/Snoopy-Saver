#!/usr/bin/env python3
"""Validate a normalized standard/low-resolution/CDN-lite asset tree."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--lowres", action="store_true")
    parser.add_argument("--allow-missing-video", action="store_true")
    parser.add_argument("--expected-assets", type=int, default=433)
    parser.add_argument("--expected-videos", type=int, default=319)
    parser.add_argument("--jobs", type=int, default=4)
    return parser.parse_args()


def probe(ffprobe: str, path: Path) -> tuple[Path, list[dict]]:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "stream=codec_name,codec_type,codec_tag_string,pix_fmt,width,height",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return path, json.loads(result.stdout).get("streams", [])


def main() -> int:
    args = parse_args()
    root = args.root.expanduser().resolve()
    assets = root / "Assets" / "Resolved"
    directories = sorted(assets.glob("*.icasset"))
    failures: list[str] = []
    if len(directories) != args.expected_assets:
        failures.append(
            f"expected {args.expected_assets} unique assets, found {len(directories)}"
        )
    if len({directory.stem for directory in directories}) != len(directories):
        failures.append("duplicate Asset IDs")
    for directory in directories:
        metadata = directory / "metadata.icmetadata"
        if not metadata.is_file():
            failures.append(f"missing metadata: {directory.name}")
            continue
        try:
            with metadata.open("rb") as stream:
                plistlib.load(stream)
        except Exception as error:
            failures.append(f"invalid metadata {directory.name}: {error}")

    videos = sorted(assets.rglob("*.mov"))
    if not args.allow_missing_video and len(videos) != args.expected_videos:
        failures.append(
            f"expected {args.expected_videos} videos, found {len(videos)}"
        )
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=max(1, min(args.jobs, 8))
    ) as pool:
        futures = [pool.submit(probe, args.ffprobe, video) for video in videos]
        for future in concurrent.futures.as_completed(futures):
            try:
                path, streams = future.result()
            except Exception as error:
                failures.append(f"ffprobe failed: {error}")
                continue
            video_streams = [
                stream for stream in streams if stream.get("codec_type") == "video"
            ]
            disallowed_streams = [
                stream
                for stream in streams
                if stream.get("codec_type") != "video"
                and not (
                    stream.get("codec_type") == "data"
                    and stream.get("codec_tag_string") == "tmcd"
                )
            ]
            if len(video_streams) != 1 or disallowed_streams:
                failures.append(
                    f"{path.name}: expected one video stream and optional timecode, got {streams}"
                )
                continue
            stream = video_streams[0]
            if args.lowres and (
                stream.get("codec_name") != "hevc"
                or stream.get("pix_fmt") != "yuv420p"
                or int(stream.get("width", 0)) > 1920
                or int(stream.get("height", 0)) > 1080
            ):
                failures.append(f"{path.name}: invalid low-resolution stream {stream}")

    alpha_count = 0
    if args.lowres:
        alpha_manifest = root / "alpha-preservation.json"
        if not alpha_manifest.is_file():
            failures.append("missing alpha-preservation.json; Apple HEVC alpha was not restored")
        else:
            try:
                alpha_document = json.loads(alpha_manifest.read_text(encoding="utf-8"))
                alpha_files = alpha_document.get("files", [])
                alpha_count = int(alpha_document.get("alphaMovieCount", -1))
                if alpha_count != len(alpha_files) or alpha_count <= 0:
                    failures.append(
                        "alpha-preservation.json has an invalid alpha movie count"
                    )
                destinations: set[str] = set()
                for record in alpha_files:
                    relative = Path(str(record.get("destination", "")))
                    if (
                        relative.is_absolute()
                        or ".." in relative.parts
                        or relative.suffix.lower() != ".mov"
                    ):
                        failures.append(f"unsafe alpha destination: {relative}")
                        continue
                    if relative.as_posix() in destinations:
                        failures.append(f"duplicate alpha destination: {relative}")
                    destinations.add(relative.as_posix())
                    if (
                        not args.allow_missing_video
                        and not (assets / relative).is_file()
                    ):
                        failures.append(f"missing preserved alpha movie: {relative}")
            except Exception as error:
                failures.append(f"invalid alpha-preservation.json: {error}")

    result = {
        "assetCount": len(directories),
        "videoCount": len(videos),
        "heicCount": len(list(assets.rglob("*.heic"))),
        "alphaVideoCount": alpha_count,
        "failureCount": len(failures),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if failures:
        for failure in failures[:100]:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
