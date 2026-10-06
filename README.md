# HFSViewer

A macOS application for accessing HFS volumes on modern Apple Silicon Macs.

## Purpose

This app was created to access an HFS-formatted USB 2.0 drive on a modern M4 Mac. macOS no longer natively supports mounting classic HFS volumes, making it difficult to read data from older Mac-formatted drives and disk images.

## Features

- Browse HFS (classic) volumes
- Export files with their resource forks and Finder type/creator codes
- View file metadata (dates, type/creator codes, fork sizes)
- Navigate directory structures
- Open raw images (.img, .iso, .toast), compressed disk images (.dmg), and devices like CD drives
- Partitioned media (e.g. CDs with an Apple Partition Map), including disks with several HFS volumes

## What's Included

This project contains:

- **com.maxleiter.HFSViewer** - Swift/SwiftUI macOS application
- **hfsutils** - Classic HFS tools by Robert Leslie et al. (GPL v2+)

## License

This entire project is licensed under the **GNU General Public License v3** (GPL v3).

## Attribution

- **hfsutils**: Copyright 1996-1998 Robert Leslie, modernized by Brock Gunter-Smith and Pablo Lezaeta - <https://github.com/JotaRandom/hfsutils>
- **HFSViewer app**: Copyright 2026 Max Leiter

## Building

### Quick Release Build

```bash
./build-release.sh
```

This creates a release build and packages it as a zip file in the `releases/` directory.

### Manual Build

Open the `.xcodeproj` file in the `com.maxleiter.HFSViewer` directory in Xcode and build.

The project links against `libs/libhfs.a`, built from `hfsutils/libhfs`. After changing libhfs, rebuild it with:

```bash
./build-libhfs.sh
```

## Usage

1. Launch the app
2. Click "Open File or Disk Image..." (or press ⌘O) and choose an image, or click "Open Device Path..." and enter a device such as `/dev/disk4` (find it with `diskutil list`)
3. Browse the volume contents. If the disk has several HFS volumes, pick one under "Partitions" in the sidebar

## Requirements

- macOS 14.0 or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

## Notes

- This app provides read-only access to HFS volumes by default.
- Write access is in beta and not recommended.
- HFS+ (Mac OS Extended) volumes aren't supported here, but macOS can open those directly.
