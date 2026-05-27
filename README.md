# r36-tools

Three utilities for dealing with R36 handheld SD cards, bundled into one script. Runs on macOS and Linux.

## What it does

**push** -- copies files and folders onto an SD card partition. You point it at whatever you want to move (roms, themes, whatever), pick the partition, pick the destination folder, and it copies everything with retries and a progress bar. It handles the cheap SD card dropout problem.

**write** -- writes a .img file to a raw SD card using dd. Same dropout handling, split into chunks so if the card flakes out mid-write it retries that chunk instead of dying. Supports resume from an offset if a previous write failed partway. Has an optional verify step (md5 of first 512MB).

**encode** -- re-encodes video (MP4) or audio (MP3) for the R36 screen (640x480, H.264 Main L3.1, 30fps, AAC audio) and copies the result to your SD card in one shot. Requires ffmpeg.

## Requirements

- **push/encode**: macOS or Linux with zsh
- **write**: macOS or Linux with zsh, sudo access for dd
- **encode**: additionally needs ffmpeg

## Usage

    ./r36-tools.sh

An interactive menu walks you through selecting files, picking a disk or partition, and confirming before doing anything destructive.

## Why it exists

R36 ships with a cheap SD card that drops out under load. These tools retry on failure, remount when the card disconnects, and log everything to /tmp so you can see what went wrong after the fact. The encode tool exists because the R36 screen is 640x480 and most video files are not, and will stutter on the RK3326 if you don't use the right settings.

On Linux, the script detects USB and mmcblk devices via lsblk and uses udisksctl for mounting. On macOS it uses diskutil.

## Notes

- Write erases everything on the target disk. It will ask for confirmation.
- Push and encode operate at the partition level -- they copy files, not raw blocks.
- Logs go to /tmp/r36_YYYYMMDD_HHMMSS.log.
- Tested on macOS Sequoia and Debian/Ubuntu.
