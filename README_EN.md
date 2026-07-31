> [!WARNING]
> **Current signing status and first-launch instructions**
>
> Snoopy is currently ad-hoc signed. It is not yet signed with an Apple Developer ID or notarized by Apple. macOS may report that the developer cannot be verified or block the saver from opening. Only if you trust the source: try to open it once, then go to **System Settings → Privacy & Security**, scroll to the bottom, choose **Open Anyway** next to the relevant warning, and confirm again.
>
> Contributors familiar with macOS Developer ID, Hardened Runtime, and notarization are welcome to discuss a safe release workflow in an [Issue](../../issues) or submit a Pull Request improving the build/signing pipeline. Never upload certificates, private keys, or signing credentials to an Issue, PR, or repository.

# Snoopy Saver

[简体中文](README.md) · **English**

> [!IMPORTANT]
> **Latest release: Snoopy 1.1 (V1.1.0) · July 21, 2026**
>
> Version 1.1 focuses on long-running efficiency: it fixes elevated energy use, fan activity, and IdleScene frame drops; restructures the lifecycle of players, layers, HEIC decoding caches, and background work; and adds a new System Settings thumbnail.
>
> - [GitHub Release: split download and full release notes](https://github.com/Cyber-Yichen/Snoopy-Saver/releases/tag/V1.1.0)—download the installer ZIP and all four DMG parts, place them in one folder, then run the installer.
> - [Baidu Netdisk: complete archive](https://pan.baidu.com/s/17pI0PTYSRbr7G-a06zrEBg?pwd=f2vm)—file `SnoopyScreenSaver 1.1zip.zip`, extraction code `f2vm`.

Snoopy Saver aims to bring the Snoopy screen saver from tvOS to macOS as completely as possible. It preserves the full-screen animated stories while rebuilding the layered scenes made from backgrounds, characters, visitors, weather effects, and palettes. The next scene is selected using date, time, weather, and recent play history.

The project has achieved:

- a complete scene catalog reconstructed from the tvOS 26.5 Simulator;
- layered IdleScenes with the original halftone look and continuous character motion;
- all five official transition families, aligned with the end of each full-screen movie;
- special scenes for holidays, Snoopy's birthday, time periods, weather, and routines;
- a universal screen-saver build for both Apple Silicon and Intel Macs.

## What you can see

Using the tvOS 26.5 asset set tested by this project:

| Content | Count / behavior |
| --- | --- |
| Full-screen stories | 65 ActiveScenes |
| Layered ambient scenes | 39 IdleScenes |
| Environment palettes | 84 date, time, and weather palettes |
| Official transitions | 5 families: horizontal, clock, circular, thought bubble, and sleeping dream bubble |
| Special content | Holidays, seasons, Snoopy's birthday, sunrise/sunset, weather, moon phases, and more |

At launch, the saver has an equal chance of starting with a full-screen story or a layered scene. An IdleScene normally lasts 20–60 seconds, with changing Snoopy actions and occasional Woodstock or visitor appearances, before a full-screen story is inserted. There is no sound, clock, or text overlay.

### Times and seasons

The following scenes were selected by running the final catalog through its actual date, time, and weather scoring. Other tied scenes may appear under the same conditions, and recent play history can change the final selection.

<table>
  <tr>
    <td width="50%"><img src="Assets/spring-morning.jpg" alt="Spring morning"><br><sub>Spring morning · Sunny</sub></td>
    <td width="50%"><img src="Assets/summer-afternoon.jpg" alt="Summer afternoon"><br><sub>Summer afternoon · Clear</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Assets/autumn-evening.jpg" alt="Autumn evening"><br><sub>Autumn evening · Windy</sub></td>
    <td width="50%"><img src="Assets/winter-late-night.jpg" alt="Winter late night"><br><sub>Winter late night · Snowy</sub></td>
  </tr>
</table>

### August 10: Snoopy's birthday surprise

On August 10, date relevance prioritizes Snoopy birthday content. A smoke test confirmed that the dedicated full-screen story, layered scene, visitor, and character action can all be selected across morning, afternoon, evening, and late-night fixtures.

![Snoopy birthday scene selected on August 10](Assets/birthday-aug10.jpg)

<sub>Test date: 2026-08-10, Asia/Shanghai; captured from the full-screen birthday scene.</sub>

> This repository contains the screen-saver implementation, build/install scripts, and System Settings thumbnails only. It does not include asset-acquisition code, test tools, implementation notes, runtime Apple or Peanuts media, or a built `.saver` bundle. The few low-resolution screenshots in the README are included only as feature previews and test records.

## How it works

```mermaid
flowchart TD
    A[Start screen saver] --> B[Fade in from black]
    B --> C{First scene: 50 / 50}
    C --> D[Layered IdleScene]
    C --> E[Full-screen ActiveScene]
    D --> F[Date / time / weather / recency scoring]
    F --> G[Character actions, visitors, and effects]
    G -->|20–60 seconds| E
    E --> H[Preload the next IdleScene]
    H --> I[Official transition aligned to movie end]
    I --> D
```

## Technology

- Swift 5, AppKit, and `ScreenSaver.framework`
- AVFoundation for full-screen movies, phased actions, and preloading
- Core Animation for layer composition, masks, and transitions
- Core Location + Open-Meteo for optional weather, sunrise, and sunset matching
- ImageIO for HEIC sequence decoding with a bounded cache
- Shell scripts for universal builds and installation helpers

The minimum deployment target is macOS 12. Layout tests cover 16:9, 16:10, 3:2, 21:9, and 4:3 displays without stretching the artwork.

## Build from source

Requirements:

- macOS and Xcode
- local assets that the user is legally authorized to access

```bash
Scripts/build_saver.sh
```

This repository does not provide assets, downloaders, decryption tools, or asset-acquisition instructions. A full build requires users to prepare assets they are legally authorized to access and place them under the `LocalAssets/` layout expected by the build script. To validate code compilation without packaging media, run:

```bash
Scripts/build_saver.sh --code-only
```

Every local media path is excluded by `.gitignore`.

Install a local build with:

```bash
Scripts/install_saver.sh
```

## Security and stability

Pre-release validation includes:

- AddressSanitizer playback and layer-handoff tests;
- 12 forced scene changes without a crash, black frame, or layer accumulation;
- a 192 MB HEIC cache limit, purged when the saver stops;
- explicit cleanup for players, prerolls, notifications, KVO, time observers, location, and network sessions;
- no external process execution, third-party binary, or executable resource at runtime;
- HTTPS-only Open-Meteo requests through an ephemeral, cookie-free, disk-cache-free session with timeouts and a response-size limit.

Measured resident memory was about 295 MB at baseline and about 568 MB while overlapping two 4K scenes during a transition. All root layers were removed after stopping. Results vary by media, resolution, and macOS version.

## Contributing

Issues are welcome for black screens, aspect ratios, transitions, scene selection, and compatibility. Pull Requests are welcome as well. For signing, notarization, or release automation, contribute workflows, configuration, and documentation only—never personal certificates or keys.

Before submitting, confirm that:

- no `LocalAssets/`, MOV, HEIC, `.saver`, or other Apple/Peanuts media is included;
- the code builds and relevant smoke tests pass;
- new behavior compiles for both Apple Silicon and Intel targets.

## Disclaimer

This is an independent, unofficial project for learning and technical discussion. It is not affiliated with, authorized by, endorsed by, or sponsored by **Peanuts Worldwide, Peanuts, Apple Inc.**, or any of their affiliates.

Snoopy, Peanuts, and related characters, names, and media belong to their respective rights holders. Apple, tvOS, macOS, and related trademarks and media belong to Apple Inc. This repository provides no license or redistribution rights for third-party media. Use the project only where permitted by applicable law and with assets you are legally authorized to access on your own devices and Simulator installations.
