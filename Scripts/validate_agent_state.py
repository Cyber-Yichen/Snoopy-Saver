#!/usr/bin/env python3
"""Validate the machine-readable Agent contract against product metadata."""

from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"agent state error: {message}", file=sys.stderr)
    raise SystemExit(1)


root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
state_path = root / ".agents" / "project-state.json"
info_path = root / "Info.plist"
build_path = root / "Scripts" / "build_saver.sh"
screen_saver_view_path = root / "Sources" / "ScreenSaverView.swift"

try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    build_script = build_path.read_text(encoding="utf-8")
    screen_saver_view = screen_saver_view_path.read_text(encoding="utf-8")
except (OSError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
    fail(str(error))

if state.get("schemaVersion") != 1:
    fail("unsupported or missing schemaVersion")

product = state.get("product", {})
metadata_pairs = {
    "shortVersion": "CFBundleShortVersionString",
    "internalBuild": "CFBundleVersion",
    "minimumMacOS": "LSMinimumSystemVersion",
}
for state_key, plist_key in metadata_pairs.items():
    declared = str(product.get(state_key, ""))
    actual = str(info.get(plist_key, ""))
    if not declared or declared != actual:
        fail(f"product.{state_key}={declared!r} does not match {plist_key}={actual!r}")

architectures = product.get("architectures")
if architectures != ["arm64", "x86_64"]:
    fail("product.architectures must remain ['arm64', 'x86_64']")

variants = state.get("variants", {})
expected_variants = ("standard", "1080p", "cdn-lite")
if set(variants) != set(expected_variants):
    fail(f"variants must contain exactly: {', '.join(expected_variants)}")

case_pattern = re.compile(
    r"^  (standard|1080p|cdn-lite)\)\n(?P<body>.*?)(?=^  (?:standard|1080p|cdn-lite|\*)\))",
    re.MULTILINE | re.DOTALL,
)
case_bodies = {match.group(1): match.group("body") for match in case_pattern.finditer(build_script)}
if set(case_bodies) != set(expected_variants):
    fail("could not locate all three variant cases in Scripts/build_saver.sh")

field_to_shell_name = {
    "bundleIdentifier": "BUNDLE_ID",
    "principalClass": "PRINCIPAL_CLASS",
    "swiftModule": "MODULE_NAME",
}
for variant_name in expected_variants:
    declaration = variants.get(variant_name, {})
    body = case_bodies[variant_name]
    for field_name, shell_name in field_to_shell_name.items():
        expected = declaration.get(field_name)
        match = re.search(rf'^    {shell_name}="([^"]+)"$', body, re.MULTILINE)
        actual = match.group(1) if match else None
        if not expected or expected != actual:
            fail(
                f"variants.{variant_name}.{field_name}={expected!r} "
                f"does not match {shell_name}={actual!r}"
            )

for field_name in field_to_shell_name:
    values = [variants[name][field_name] for name in expected_variants]
    if len(values) != len(set(values)):
        fail(f"variant {field_name} values must be unique")

frozen = state.get("frozenBehavior", {})
if frozen.get("coldStartIdleProbability") != 0.5:
    fail("cold-start Idle probability must remain 0.5 until explicitly changed")
if frozen.get("idleDurationSeconds") != {"minimum": 20, "maximum": 60}:
    fail("Idle duration contract must remain 20-60 seconds until explicitly changed")
if frozen.get("audio") is not False or frozen.get("clockOrTextOverlay") is not False:
    fail("audio and clock/text overlay must remain disabled until explicitly changed")

if "Bool.random() ? playIdle() : playActive()" not in screen_saver_view:
    fail("ScreenSaverView no longer implements the declared 50/50 cold start")
idle_range = frozen["idleDurationSeconds"]
idle_expression = f'Double.random(in: {idle_range["minimum"]}...{idle_range["maximum"]})'
if screen_saver_view.count(idle_expression) < 2:
    fail("ScreenSaverView does not consistently implement the declared Idle duration range")

print("Agent state contract passed: product metadata and three variants agree.")
