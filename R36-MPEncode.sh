#!/bin/zsh
# ============================================================
#  r36-encode.sh — R36 Media Re-Encoder for macOS
#  Re-encodes MP3 or MP4 to R36-optimal settings, then
#  pushes the result to your SD card — just like cpush.
#
#  R36 targets  (RK3326 · 640×480 4:3 IPS · Mali-G31):
#  VIDEO  H.264 Main L3.1 · CRF 23 · 640×480 pad · 30 fps
#         yuv420p · maxrate 1500k · faststart
#  AUDIO  AAC-LC · 44100 Hz · stereo · 128 kbps (video)
#         192 kbps (audio-only → .m4a)
# ============================================================

# ── Colours (exact cpush palette) ───────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
R='\033[0m'

# ── Globals ──────────────────────────────────────────────────
typeset -g DISK_NUM=""
typeset -g DISK=""
typeset -g PARTITION=""
typeset -g MOUNT_POINT=""
typeset -g INPUT_FILE=""
typeset -g OUTPUT_FILE=""
typeset -g MAX_RETRIES=8
typeset -g RETRY_DELAY=5
typeset -g CACHE_THRESHOLD=50
typeset -g LOG_FILE="/tmp/r36_encode_$(date +%Y%m%d_%H%M%S).log"
typeset -g GRAND_START=0

# ── Logging ──────────────────────────────────────────────────
log() { print "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" }

# ── Time formatter (from cpush) ──────────────────────────────
format_time() {
    local s=$1
    (( s < 0 )) && s=0
    local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    if   (( h > 0 )); then printf "%dh %02dm %02ds" $h $m $sec
    elif (( m > 0 )); then printf "%dm %02ds" $m $sec
    else printf "%ds" $sec
    fi
}

# ── Progress bar (from cpush) ────────────────────────────────
progress_bar() {
    local cur=$1 tot=$2 width=38
    local pct=0
    (( tot > 0 )) && pct=$(( cur * 100 / tot ))
    local filled=$(( pct * width / 100 ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=filled; i<width; i++ )); do bar+="░"; done
    printf "[%s] %3d%%" "$bar" "$pct"
}

# ── Encode progress UI (mirrors cpush draw_ui) ───────────────
draw_encode_ui() {
    local stage="$1"      # "Encoding" or "Copying"
    local file_name="$2"
    local pct_num=$3      # 0-100 for encode; file bytes for copy
    local pct_tot=$4
    local elapsed=$5
    local eta="$6"
    local extra="$7"      # codec line or speed

    tput cup 0 0
    tput ed

    print "${BOLD}${CYAN}  R36 MEDIA ENCODER${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
    print ""
    printf "  ${BOLD}Stage:${R}    %s\n" "$stage"
    printf "  ${DIM}File:${R}     %s\n" "$file_name"
    [[ -n "$extra" ]] && printf "  ${DIM}Info:${R}     %s\n" "$extra"
    print ""
    printf "  Progress: "
    progress_bar "$pct_num" "$pct_tot"
    printf "\n"
    print ""
    printf "  ${GREEN}Elapsed:${R}  %s\n" "$(format_time $elapsed)"
    printf "  ${GREEN}ETA:${R}      %s\n" "$eta"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
}

# ── Dependency check ─────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in ffmpeg ffprobe diskutil; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        print "  ${RED}✖  Missing: ${missing[*]}${R}"
        print "  ${DIM}Install ffmpeg:  brew install ffmpeg${R}"
        exit 1
    fi
}

# ── Audio encoder flags ──────────────────────────────────────
audio_encoder_flags() {
    if ffmpeg -encoders 2>/dev/null | grep -q libfdk_aac; then
        print -- "-c:a libfdk_aac -vbr 3"
    else
        print -- "-c:a aac -q:a 2"
    fi
}

# ── Source file selection ─────────────────────────────────────
select_source() {
    print "\n${BOLD}  Source file:${R}"
    print "  ${DIM}Enter the full path to your MP3 or MP4 file.${R}\n"
    printf "  ${CYAN}Path: ${R}"
    read -r INPUT_FILE
    INPUT_FILE="${INPUT_FILE//\'/}"
    INPUT_FILE="${INPUT_FILE//\\ / }"

    [[ ! -f "$INPUT_FILE" ]] && { print "  ${RED}Not found: $INPUT_FILE${R}"; exit 1 }

    local ext="${INPUT_FILE:e:l}"   # zsh lowercase extension
    if [[ "$ext" != "mp4" && "$ext" != "mp3" ]]; then
        print "  ${RED}Unsupported type '.${ext}'. Only MP3 and MP4 are supported.${R}"
        exit 1
    fi

    local bytes
    bytes=$(stat -f%z "$INPUT_FILE" 2>/dev/null || print 0)
    print "  ${GREEN}File:${R} $(basename $INPUT_FILE)  ${DIM}($bytes bytes)${R}"
    log "SOURCE: $INPUT_FILE ($bytes bytes)"
}

# ── Disk selection (exact cpush logic) ───────────────────────
select_disk() {
    print "\n${BOLD}  Scanning for external disks...${R}\n"

    local tmpfile
    tmpfile=$(mktemp)
    diskutil list 2>/dev/null | grep "external" | awk '{print $1}' | sed 's|/dev/disk||' > "$tmpfile"

    local count=0
    local -a nums
    while IFS= read -r num; do
        [[ -z "$num" ]] && continue
        local size name
        size=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Disk Size" | awk '{print $3, $4}')
        name=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Device / Media Name" | cut -d: -f2 | xargs)
        (( count++ ))
        nums+=("$num")
        print "  ${GREEN}[$count]${R} /dev/disk${num}  ${BOLD}$size${R}  ${DIM}$name${R}"
    done < "$tmpfile"
    rm -f "$tmpfile"

    (( count == 0 )) && { print "  ${RED}No external disks found. Insert your SD card first.${R}"; exit 1 }

    print ""
    if (( count == 1 )); then
        DISK_NUM="${nums[1]}"
        print "  ${CYAN}Auto-selected: /dev/disk${DISK_NUM}${R}"
    else
        printf "  ${BOLD}Select [1-%d]: ${R}" $count
        read -r choice
        (( choice < 1 || choice > count )) && { print "  ${RED}Invalid.${R}"; exit 1 }
        DISK_NUM="${nums[$choice]}"
    fi
    DISK="/dev/disk${DISK_NUM}"
}

# ── Partition selection (exact cpush logic) ──────────────────
select_partition() {
    print "\n  Partitions on ${BOLD}${DISK}${R}:\n"
    diskutil list "$DISK"
    print ""
    printf "  ${BOLD}Partition slice (e.g. s1): ${R}"
    read -r slice
    [[ -z "$slice" ]] && { print "  ${RED}No partition selected.${R}"; exit 1 }
    PARTITION="$slice"
    diskutil info "${DISK}${PARTITION}" >/dev/null 2>&1 || \
        { print "  ${RED}${DISK}${PARTITION} not found.${R}"; exit 1 }
}

# ── Mount (exact cpush logic) ────────────────────────────────
mount_partition() {
    local target="${DISK}${PARTITION}"
    print "\n${BOLD}  Mounting ${target}...${R}"

    local mount_pt
    mount_pt=$(diskutil info "$target" 2>/dev/null | grep "Mount Point" | cut -d: -f2 | xargs)

    if [[ -n "$mount_pt" && -d "$mount_pt" && "$mount_pt" != "Not applicable" ]]; then
        MOUNT_POINT="$mount_pt"
        print "  ${GREEN}Already mounted at: $MOUNT_POINT${R}"
        return 0
    fi

    diskutil mount "$target" >/dev/null 2>&1
    mount_pt=$(diskutil info "$target" 2>/dev/null | grep "Mount Point" | cut -d: -f2 | xargs)

    if [[ -n "$mount_pt" && -d "$mount_pt" ]]; then
        MOUNT_POINT="$mount_pt"
        print "  ${GREEN}Mounted at: $MOUNT_POINT${R}"
        return 0
    fi

    print "  ${RED}Could not mount ${target}.${R}"
    exit 1
}

# ── Destination browser (exact cpush list_and_select_dest) ───
select_dest() {
    local out_name
    out_name=$(basename "$OUTPUT_FILE")

    print "\n${BOLD}  Destination for: ${CYAN}${out_name}${R}"
    print "  ${DIM}Listing $MOUNT_POINT:${R}\n"

    local tmpfile
    tmpfile=$(mktemp)

    print "  ${GREEN}[0]${R} ${BOLD}/ (partition root)${R}  =>  $MOUNT_POINT"
    print "$MOUNT_POINT" >> "$tmpfile"

    local idx=0
    while IFS= read -r entry; do
        [[ ! -d "$entry" ]] && continue
        (( idx++ ))
        local rel="${entry#$MOUNT_POINT/}"
        printf "  ${GREEN}[%d]${R} /%s\n" $idx "$rel"
        print "$entry" >> "$tmpfile"
    done < <(find "$MOUNT_POINT" -mindepth 1 -maxdepth 2 -type d | sort)

    print ""
    print "  ${DIM}Encoded file will be placed directly into the chosen folder.${R}"
    print ""
    printf "  ${BOLD}Select [0-%d]: ${R}" $idx
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > idx )); then
        print "  ${RED}Invalid selection.${R}"
        rm -f "$tmpfile"
        exit 1
    fi

    local dest
    dest=$(sed -n "$((choice+1))p" "$tmpfile")
    rm -f "$tmpfile"

    [[ -z "$dest" ]] && { print "  ${RED}Could not resolve destination.${R}"; exit 1 }

    # Rebuild OUTPUT_FILE with chosen dest dir, keeping _r36 filename
    OUTPUT_FILE="${dest}/$(basename $OUTPUT_FILE)"

    if [[ -f "$OUTPUT_FILE" ]]; then
        print "  ${YELLOW}'$(basename $OUTPUT_FILE)' already exists — will overwrite.${R}"
    fi

    print "  ${GREEN}=> $dest${R}"
    log "DEST: $OUTPUT_FILE"
}

# ── Remount (exact cpush) ────────────────────────────────────
remount() {
    diskutil unmount "${DISK}${PARTITION}" >/dev/null 2>&1
    sleep $RETRY_DELAY
    diskutil mount "${DISK}${PARTITION}" >/dev/null 2>&1
    sleep 2
    local new_mp
    new_mp=$(diskutil info "${DISK}${PARTITION}" 2>/dev/null | grep "Mount Point" | cut -d: -f2 | xargs)
    [[ -n "$new_mp" && -d "$new_mp" ]] && MOUNT_POINT="$new_mp"
}

# ── Encode with live draw_ui progress ────────────────────────
run_encode() {
    local src="$1" dst_tmp="$2" type="$3"
    local aenc
    aenc=$(audio_encoder_flags)
    local fname
    fname=$(basename "$src")
    local stage="Encoding (${type:u})"
    local extra=""

    # Get total duration in seconds via ffprobe
    local duration=0
    duration=$(ffprobe -v quiet -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || print 0)
    duration=${duration%.*}
    (( duration < 1 )) && duration=1

    local encode_start
    encode_start=$(date +%s)

    tput civis 2>/dev/null
    clear

    if [[ "$type" == "mp4" ]]; then
        extra="H.264 Main · 640×480 · 30fps · CRF23 · AAC 128k"
        ffmpeg -y -i "$src" \
            -vf "scale=640:480:force_original_aspect_ratio=decrease,\
pad=640:480:(ow-iw)/2:(oh-ih)/2:black,\
format=yuv420p" \
            -c:v libx264 -profile:v main -level:v 3.1 \
            -preset slow -crf 23 -maxrate 1500k -bufsize 3000k \
            -r 30 -movflags +faststart \
            ${=aenc} -ar 44100 -ac 2 -b:a 128k \
            -progress pipe:1 \
            "$dst_tmp" 2>/dev/null | \
        while IFS='=' read -r key val; do
            if [[ "$key" == "out_time_ms" ]]; then
                local done_s=$(( val / 1000000 ))
                local elapsed=$(( $(date +%s) - encode_start ))
                local eta_s=0
                (( done_s > 0 && elapsed > 0 )) && \
                    eta_s=$(( (duration - done_s) * elapsed / done_s ))
                (( eta_s < 0 )) && eta_s=0
                draw_encode_ui "$stage" "$fname" \
                    "$done_s" "$duration" \
                    "$elapsed" "$(format_time $eta_s)" "$extra"
            fi
        done
    else
        extra="AAC-LC · 44100 Hz · stereo · 192 kbps → .m4a"
        ffmpeg -y -i "$src" \
            ${=aenc} -ar 44100 -ac 2 -b:a 192k \
            -movflags +faststart \
            -progress pipe:1 \
            "$dst_tmp" 2>/dev/null | \
        while IFS='=' read -r key val; do
            if [[ "$key" == "out_time_ms" ]]; then
                local done_s=$(( val / 1000000 ))
                local elapsed=$(( $(date +%s) - encode_start ))
                local eta_s=0
                (( done_s > 0 && elapsed > 0 )) && \
                    eta_s=$(( (duration - done_s) * elapsed / done_s ))
                (( eta_s < 0 )) && eta_s=0
                draw_encode_ui "$stage" "$fname" \
                    "$done_s" "$duration" \
                    "$elapsed" "$(format_time $eta_s)" "$extra"
            fi
        done
    fi

    # Final frame — show 100%
    local total_elapsed=$(( $(date +%s) - encode_start ))
    draw_encode_ui "$stage" "$fname" \
        "$duration" "$duration" \
        "$total_elapsed" "0s" "$extra"

    tput cnorm 2>/dev/null
    log "ENCODED: $src → $dst_tmp in $(format_time $total_elapsed)"
}

# ── Copy with retry + draw_ui (cpush copy_entry style) ───────
copy_to_card() {
    local src="$1"    # temp encoded file
    local dst="$2"    # final path on SD card
    local fname
    fname=$(basename "$src")
    local fbytes
    fbytes=$(stat -f%z "$src" 2>/dev/null || print 0)

    local retries=0 success=0
    local copy_start
    copy_start=$(date +%s)

    tput civis 2>/dev/null
    clear

    while (( retries < MAX_RETRIES && !success )); do
        local now elapsed eta_s=0
        now=$(date +%s)
        elapsed=$(( now - copy_start ))

        draw_encode_ui "Copying to SD card" "$fname" \
            "0" "1" \
            "$elapsed" "..." \
            "Attempt $((retries+1)) of $MAX_RETRIES"

        local ft0 ft1
        ft0=$(date +%s)
        cp "$src" "$dst" 2>/dev/null
        local rc=$?
        ft1=$(date +%s)

        local fdur=$(( ft1 - ft0 )) fspeed=0
        (( fdur > 0 )) && fspeed=$(( fbytes / 1048576 / fdur ))

        if (( rc == 0 )); then
            success=1
            (( fspeed > CACHE_THRESHOLD )) && \
                log "CACHE? $fname @ ${fspeed}MB/s" || \
                log "OK: $fname @ ${fspeed}MB/s"
            # Final display — show 100%
            elapsed=$(( $(date +%s) - copy_start ))
            draw_encode_ui "Copying to SD card" "$fname" \
                "1" "1" \
                "$elapsed" "0s" \
                "${fspeed}MB/s"
        else
            (( retries++ ))
            log "RETRY $retries: $fname"
            draw_encode_ui "Copying to SD card — RETRYING" "$fname" \
                "0" "1" "$elapsed" "..." \
                "Retry $retries/$MAX_RETRIES — remounting…"
            remount
        fi
    done

    tput cnorm 2>/dev/null

    if (( !success )); then
        log "FAILED: $fname after $MAX_RETRIES retries"
        print "\n  ${RED}✖  Copy failed after $MAX_RETRIES retries. Check log: $LOG_FILE${R}\n"
        exit 1
    fi
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
main() {
    clear
    print "${BOLD}${CYAN}  R36 MEDIA ENCODER${R}"
    print "  ${DIM}macOS / diskutil / zsh / ffmpeg${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"

    check_deps

    # ── 1. Source file ───────────────────────────────────────
    select_source

    # ── 2. Build temp output filename ───────────────────────
    local ext="${INPUT_FILE:e:l}"
    local base="${INPUT_FILE:t:r}"          # filename without extension
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if [[ "$ext" == "mp4" ]]; then
        OUTPUT_FILE="${tmp_dir}/${base}_r36.mp4"
    else
        OUTPUT_FILE="${tmp_dir}/${base}_r36.m4a"
    fi

    # ── 3. SD card selection ─────────────────────────────────
    select_disk
    select_partition
    mount_partition

    # ── 4. Destination folder on SD card ────────────────────
    select_dest

    # ── 5. Summary + confirm ─────────────────────────────────
    print "\n${BOLD}  Summary:${R}"
    print "  ${CYAN}Source:${R}  $INPUT_FILE"
    print "  ${CYAN}Encode:${R}  $(basename $OUTPUT_FILE)  ${DIM}(temp: $tmp_dir)${R}"
    print "  ${CYAN}Target:${R}  $OUTPUT_FILE"
    print ""
    printf "  ${BOLD}${GREEN}Press ENTER to encode + push...${R}"
    read -r

    GRAND_START=$(date +%s)
    log "START: $INPUT_FILE → $OUTPUT_FILE"

    # ── 6. Encode ────────────────────────────────────────────
    local tmp_out="${tmp_dir}/$(basename $OUTPUT_FILE)"
    run_encode "$INPUT_FILE" "$tmp_out" "$ext"

    [[ ! -f "$tmp_out" ]] && { print "\n  ${RED}✖  Encoding failed.${R}\n"; exit 1 }

    # ── 7. Copy to SD card ───────────────────────────────────
    copy_to_card "$tmp_out" "$OUTPUT_FILE"

    # ── 8. Cleanup temp ──────────────────────────────────────
    rm -f "$tmp_out"
    rmdir "$tmp_dir" 2>/dev/null

    # ── 9. Done ──────────────────────────────────────────────
    local total_elapsed=$(( $(date +%s) - GRAND_START ))
    clear
    print "${BOLD}${CYAN}  R36 MEDIA ENCODER — Done${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
    print ""
    print "  ${GREEN}File:${R}     $(basename $OUTPUT_FILE)"
    print "  ${GREEN}Saved to:${R} $(dirname $OUTPUT_FILE)"

    local out_bytes
    out_bytes=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || print 0)
    local human
    if   (( out_bytes >= 1073741824 )); then human="$(echo "scale=2; $out_bytes/1073741824" | bc) GB"
    elif (( out_bytes >= 1048576 ));    then human="$(echo "scale=2; $out_bytes/1048576"    | bc) MB"
    else human="${out_bytes} B"; fi
    print "  ${GREEN}Size:${R}     $human"
    print "  ${GREEN}Time:${R}     $(format_time $total_elapsed)"
    print "  ${DIM}Log:      $LOG_FILE${R}"
    print ""

    # Stream info summary
    print "  ${DIM}Stream info:${R}"
    ffprobe -v quiet -show_streams -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate,bit_rate \
        -of default=noprint_wrappers=1 "$OUTPUT_FILE" 2>/dev/null | \
        sed 's/^/    /' || true
    ffprobe -v quiet -show_streams -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,channels,bit_rate \
        -of default=noprint_wrappers=1 "$OUTPUT_FILE" 2>/dev/null | \
        sed 's/^/    /' || true
    print ""

    log "COMPLETE: $(basename $OUTPUT_FILE) — $(format_time $total_elapsed)"
}

main "$@"
