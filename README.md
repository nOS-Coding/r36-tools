# r36s-tools

Three macOS utilities for dealing with R36S handheld SD cards, bundled into one script.

## What it does

**push** -- copies files and folders onto an SD card partition. You point it at whatever you want to move (roms, themes, whatever), pick the partition, pick the destination folder, and it copies everything with retries and a progress bar. Handles the cheap SD card dropout problem.

**write** -- writes a .img file to a raw SD card using dd. Same dropout handling, split into chunks so if the card flakes out mid-write it retries that chunk instead of dying. Supports resume from an offset if a previous write failed partway. Has an optional verify step (md5 of first 512MB).

**encode** -- re-encodes video (MP4) or audio (MP3) for the R36S screen (640x480, H.264 Main L3.1, 30fps, AAC audio) and copies the result to your SD card in one shot. Requires ffmpeg.

## Requirements

macOS. That's it for push and write. Encode needs ffmpeg (`brew install ffmpeg`). Write needs sudo for dd access to the raw disk device.

## Usage

    chmod +x r36s-tools.sh
    ./r36s-tools.sh push
    ./r36s-tools.sh write
    ./r36s-tools.sh encode

Each one is interactive -- it walks you through selecting files, picking a disk/partition, and confirming before it does anything destructive.

## Why it exists

R36S comes with a cheap SD card that drops out under load. These tools retry on failure, remount when the card disconnects, and log everything to /tmp so you can see what went wrong after the fact. The encode tool exists because the R36S screen is 640x480 and most video files are not, and will stutter on the RK3326 if you don't use the right settings.

## Notes

- Write erases everything on the target disk. It will ask for confirmation.
- Push and encode operate on a partition level -- they copy files, not raw blocks.
- Logs go to /tmp/r36s_YYYYMMDD_HHMMSS.log.
- Tested on macOS Sequoia. The disk selection uses diskutil so it's macOS-only.
