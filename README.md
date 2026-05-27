
<img width="200" height="200" alt="logo" src="https://github.com/user-attachments/assets/db396868-0b30-4a51-aeb2-3f67088ce09f" />

# R36-tools

Three utilities for dealing with R36 handhelds, bundled into one script. Runs on macOS and Linux.

## What it does

**Copying files** -- copies files and folders onto an SD card partition. You point it at whatever you want to move (roms, themes, whatever), pick the partition, pick the destination folder, and it copies everything with retries and a progress bar. It handles the cheap SD card dropout problem.

**Writing images** -- writes a .img file to a raw SD card using dd. Same dropout handling, split into chunks so if the card flakes out mid-write it retries that chunk instead of dying. Supports resume from an offset if a previous write failed partway. Has an optional verify step (md5 of first 512MB).

**Encode media for R36X** -- re-encodes video (MP4) or audio (MP3) for the R36 screen (640x480, H.264 Main L3.1, 30fps, AAC audio) and copies the result to your SD card in one shot. Requires ffmpeg.

## Requirements
Just a UNIX based system (Linux-MacOS), electricity, RAM and magic(ffpmeg).

## Usage

    ./r36-tools.sh

An interactive menu walks you through selecting files, picking a disk or partition, and confirming before doing anything destructive.


## Notes

- Write erases everything on the target disk. It will ask for confirmation.
- Push and encode operate at the partition level -- they copy files, not raw blocks.
- Logs go to /tmp/r36_YYYYMMDD_HHMMSS.log.
- Tested on macOS 26(Tahoe) and Debian Linux.
