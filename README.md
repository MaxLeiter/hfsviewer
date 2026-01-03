# HFSViewer

A macOS application for accessing HFS volumes on modern Apple Silicon Macs.

## Purpose

This app was created to access an HFS-formatted USB 2.0 drive on a modern M4 Mac. macOS no longer natively supports mounting classic HFS volumes, making it difficult to read data from older Mac-formatted drives and disk images.

## Features

- Browse HFS (classic) volumes
- Read files from HFS volumes
- View file metadata (dates, permissions, sizes)
- Navigate directory structures
- Support for both disk images and physical volumes

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

The project links against the included hfsutils library.

## Usage

1. Launch the app
2. Select "Open HFS Volume..." from the File menu
3. Choose an HFS disk image or device
4. Browse the volume contents

## Requirements

- macOS 12.0 or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

## Notes

- This app provides read-only access to HFS volumes. 
- Write access is in beta and not recommended.
