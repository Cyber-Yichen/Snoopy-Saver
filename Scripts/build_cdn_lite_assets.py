#!/usr/bin/env python3
"""Create a small offline starter catalog and a manifest for omitted videos."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import shutil
import sys
from pathlib import Path
from urllib.parse import quote


KINDS = (
    "activeScene",
    "idleScene",
    "characterBasePose",
    "characterSceneTransitionPose",
)
RELEVANCY_KEYS = {"event", "timeOfDay", "routine", "condition", "hourlyEvent"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lowres_root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--active-count", type=int, default=12)
    parser.add_argument("--idle-count", type=int, default=6)
    parser.add_argument(
        "--cdn-base-url",
        default="https://cdn.snoopy.bdmzw.top/media/1.1-r2",
        help="embedded media root; the downloader may override it with --base-url",
    )
    parser.add_argument(
        "--payload-output",
        type=Path,
        help="optional deployable directory containing exactly the omitted movies",
    )
    return parser.parse_args()


def metadata(asset: Path) -> dict:
    with (asset / "metadata.icmetadata").open("rb") as stream:
        return plistlib.load(stream)


def kind(document: dict) -> str:
    for candidate in KINDS:
        if candidate in document:
            return candidate
    for candidate in document:
        if candidate in {
            "characterAdditionalPose",
            "characterMoment",
            "characterPoseTransition",
            "idleSceneVisitor",
            "spriteTransitionParameters",
        }:
            return candidate
    return "metadata"


def theme_tokens(value: object, key: str = "") -> set[str]:
    result: set[str] = set()
    if isinstance(value, dict):
        for nested_key, nested_value in value.items():
            result.update(theme_tokens(nested_value, nested_key))
    elif isinstance(value, list):
        for nested_value in value:
            result.update(theme_tokens(nested_value, key))
    elif key in RELEVANCY_KEYS and isinstance(value, str):
        result.add(f"{key}:{value}")
    return result


def year_round_assets(root: Path) -> set[str]:
    directory = root / "Assets" / "Availability" / "__yearRound"
    if not directory.is_dir():
        return set()
    return {path.stem for path in directory.glob("*.assetref")}


def choose_subset(
    candidates: list[tuple[Path, dict]], count: int, year_round: set[str]
) -> set[str]:
    candidates = sorted(
        candidates, key=lambda item: (item[0].stem not in year_round, item[0].stem)
    )
    chosen: list[tuple[Path, dict]] = []
    generic = [
        item for item in candidates
        if item[0].stem in year_round and not theme_tokens(item[1])
    ]
    chosen.extend(generic[: min(4, count)])
    covered: set[str] = set()
    while len(chosen) < min(count, len(candidates)):
        remaining = [item for item in candidates if item not in chosen]
        best = max(
            remaining,
            key=lambda item: (
                len(theme_tokens(item[1]) - covered),
                item[0].stem in year_round,
                -len(theme_tokens(item[1])),
                item[0].stem,
            ),
        )
        chosen.append(best)
        covered.update(theme_tokens(best[1]))
    return {item[0].stem for item in chosen}


def copy_tree_without_unselected_movies(
    source: Path, destination: Path, include_movies: bool
) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        target = destination / entry.name
        if entry.is_dir():
            copy_tree_without_unselected_movies(entry, target, include_movies)
        elif entry.suffix.lower() != ".mov" or include_movies:
            shutil.copy2(entry, target)


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def main() -> int:
    args = parse_args()
    lowres = args.lowres_root.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if output == lowres or output == Path("/") or output == Path.home():
        raise SystemExit(f"refusing unsafe output directory: {output}")
    payload = args.payload_output.expanduser().resolve() if args.payload_output else None
    if payload is not None and (
        payload in {lowres, output, Path("/"), Path.home()}
        or payload in output.parents
        or output in payload.parents
    ):
        raise SystemExit(f"refusing unsafe payload directory: {payload}")
    source_assets = lowres / "Assets" / "Resolved"
    if not source_assets.is_dir():
        raise SystemExit(f"missing normalized assets: {source_assets}")

    documents: dict[str, tuple[Path, dict, str]] = {}
    for asset in sorted(source_assets.glob("*.icasset")):
        document = metadata(asset)
        documents[asset.stem] = (asset, document, kind(document))
    year_round = year_round_assets(lowres)
    active = choose_subset(
        [(path, doc) for path, doc, asset_kind in documents.values() if asset_kind == "activeScene"],
        args.active_count,
        year_round,
    )
    idle = choose_subset(
        [(path, doc) for path, doc, asset_kind in documents.values() if asset_kind == "idleScene"],
        args.idle_count,
        year_round,
    )
    required_kinds = {"characterBasePose", "characterSceneTransitionPose"}
    bundled = active | idle | {
        identifier
        for identifier, (_, _, asset_kind) in documents.items()
        if asset_kind in required_kinds
    }

    destination_assets = output / "Assets" / "Resolved"
    if output.exists():
        shutil.rmtree(output)
    if payload is not None and payload.exists():
        shutil.rmtree(payload)
    destination_assets.mkdir(parents=True)
    manifest_entries: list[dict[str, object]] = []
    for identifier, (asset, _, _) in sorted(documents.items()):
        copy_tree_without_unselected_movies(
            asset, destination_assets / asset.name, include_movies=identifier in bundled
        )
        if identifier in bundled:
            continue
        for movie in sorted(asset.rglob("*.mov")):
            relative = Path(asset.name) / movie.relative_to(asset)
            if payload is not None:
                payload_movie = payload / relative
                payload_movie.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(movie, payload_movie)
            manifest_entries.append(
                {
                    "path": relative.as_posix(),
                    "size": movie.stat().st_size,
                    "sha256": digest(movie),
                    "url": (
                        args.cdn_base_url.rstrip("/")
                        + "/"
                        + quote(relative.as_posix(), safe="/")
                    ),
                }
            )

    availability = lowres / "Assets" / "Availability"
    if availability.is_dir():
        shutil.copytree(availability, output / "Assets" / "Availability")
    for name in (
        "optional-assets.json",
        "halftone_pattern.png",
        "lowres-build.json",
        "heic-build.json",
        "alpha-preservation.json",
    ):
        source = lowres / name
        if source.is_file():
            shutil.copy2(source, output / name)

    selection = {
        "schemaVersion": 1,
        "bundledActiveSceneIDs": sorted(active),
        "bundledIdleSceneIDs": sorted(idle),
        "bundledSupportAssetIDs": sorted(bundled - active - idle),
        "omittedVideoCount": len(manifest_entries),
    }
    manifest = {
        "schemaVersion": 1,
        "baseURL": args.cdn_base_url.rstrip("/"),
        "destination": "~/Library/Application Support/Snoopy/Assets/Resolved",
        "files": manifest_entries,
    }
    (output / "lite-selection.json").write_text(
        json.dumps(selection, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    (output / "cdn-manifest.json").write_text(manifest_text, encoding="utf-8")
    if payload is not None:
        (payload / "cdn-manifest.json").write_text(manifest_text, encoding="utf-8")
    print(json.dumps(selection, ensure_ascii=False, indent=2))
    if payload is not None:
        print(f"CDN payload: {payload}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
