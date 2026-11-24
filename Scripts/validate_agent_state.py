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
environment_path = root / "Sources" / "Environment.swift"

try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    build_script = build_path.read_text(encoding="utf-8")
    screen_saver_view = screen_saver_view_path.read_text(encoding="utf-8")
    environment_source = environment_path.read_text(encoding="utf-8")
except (OSError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
    fail(str(error))

if state.get("schemaVersion") != 1:
    fail("unsupported or missing schemaVersion")

repository = state.get("repository", {})
branch_model = {
    "stableBranch": "main",
    "betaBranch": "beta",
}
for field_name, expected in branch_model.items():
    if repository.get(field_name) != expected:
        fail(f"repository.{field_name} must be {expected!r}")
if repository.get("promotionOrder") != ["beta", "main"] or "alphaBranch" in repository:
    fail("repository.promotionOrder must be beta -> main")

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
if set(variants) != {"standard"}:
    fail("variants must contain only the standard build")

module_match = re.search(r"-module-name\s+(\w+)", build_script)
class_match = re.search(r"^@objc\((\w+)\)", screen_saver_view, re.MULTILINE)
standard = variants["standard"]
expected_bundle = {
    "bundleIdentifier": info.get("CFBundleIdentifier"),
    "principalClass": class_match.group(1) if class_match else None,
    "swiftModule": module_match.group(1) if module_match else None,
    "mediaPolicy": "bundled-only",
}
if None in expected_bundle.values() or standard != expected_bundle:
    fail("standard bundle identity or media policy does not match the implementation")
if standard["principalClass"] != info.get("NSPrincipalClass"):
    fail("principal class does not match Info.plist")
if re.findall(r"^for ARCH in (.+); do$", build_script, re.MULTILINE) != [" ".join(architectures)]:
    fail("build script does not match the declared architectures")

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

environment_io = frozen.get("environmentIO")
expected_environment_io = {
    "default": "offline",
    "locationAuthorization": "never",
    "network": "explicit-opt-in",
    "fallbackCoordinates": False,
    "defaultsSuite": "local.snoopy.ScreenSaver",
    "killSwitch": "SNOOPY_DISABLE_ENVIRONMENT_IO",
}
if environment_io != expected_environment_io:
    fail("environment IO contract does not match the explicit weather opt-in")
if "NSLocationWhenInUseUsageDescription" in info:
    fail("Info.plist must not advertise location use; the saver does not request it")
for banned in ("CLLocationManager", "requestWhenInUseAuthorization", "fallbackLocation"):
    if banned in environment_source:
        fail(f"Environment.swift still contains {banned}")
if "WeatherAccess.request" not in environment_source:
    fail("weather fetches must go through the explicit WeatherAccess request")

print("Agent state contract passed: standard bundle and product metadata agree.")
