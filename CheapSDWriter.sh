#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
R='\033[0m'

CHUNK_MB=10
BS=1048576
MAX_RETRIES=10
RETRY_DELAY=5
CACHE_THRESHOLD=50
LOG_FILE="/tmp/sdwriter_$(date +%Y%m%d_%H%M%S).log"
START_OFFSET=0
TOTAL_RETRIES=0
CACHE_HITS=0
REAL_WRITES=0
FAILED_CHUNKS=0
DROPS=0
DISK_NUM=""
IMG=""
IMG_SIZE=0
IMG_SIZE_MB=0
IMG_SIZE_HUMAN=""
DISK=""
RDISK=""

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

print_sep() { echo -e "${DIM}  ─────────────────────────────────────────────────────${R}"; }

format_bytes() {
    local b=$1
    if (( b > 1073741824 )); then
        echo "$(echo "scale=1; $b/1073741824" | bc) GB"
    elif (( b > 1048576 )); then
        echo "$(echo "scale=1; $b/1048576" | bc) MB"
    else
        echo "${b} B"
    fi
}

format_time() {
    local s=$1
    local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 )) sec=$(( s % 60 ))
    if (( h > 0 )); then printf "%dh %02dm %02ds" $h $m $sec
    elif (( m > 0 )); then printf "%dm %02ds" $m $sec
    else printf "%ds" $sec
    fi
}

progress_bar() {
    local cur=$1 tot=$2 width=40
    local pct=$(( tot > 0 ? cur * 100 / tot : 0 ))
    local filled=$(( pct * width / 100 ))
    local bar="" i
    for (( i = 0; i < filled; i++ )); do bar+="█"; done
    for (( i = filled; i < width; i++ )); do bar+="░"; done
    echo -n "$bar"
}

select_image() {
    echo -e "\n${BOLD}  Image file:${R}"
    echo -e "  ${DIM}Drag and drop your .img or type the full path:${R}"
    echo -ne "  ${CYAN}Path: ${R}"
    read -r IMG
    IMG="${IMG//\'/}"
    IMG="${IMG//\\ / }"

    if [[ ! -f "$IMG" ]]; then
        echo -e "  ${RED}File not found: $IMG${R}"
        exit 1
    fi

    IMG_SIZE=$(stat -f%z "$IMG")
    IMG_SIZE_MB=$(( IMG_SIZE / 1048576 ))
    IMG_SIZE_HUMAN=$(format_bytes "$IMG_SIZE")

    echo -e "  ${GREEN}Found:${R} $(basename "$IMG")"
    echo -e "  ${GREEN}Size:${R}  $IMG_SIZE_HUMAN ($IMG_SIZE_MB MB)"
}

select_disk() {
    echo -e "\n${BOLD}  Scanning for external disks...${R}\n"

    local tmpfile
    tmpfile=$(mktemp)
    diskutil list 2>/dev/null | grep "external" | awk '{print $1}' | sed 's|/dev/disk||' > "$tmpfile"

    local count=0
    local nums=()
    while IFS= read -r num; do
        [[ -z "$num" ]] && continue
        local size name
        size=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Disk Size" | awk '{print $3, $4}')
        name=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Device / Media Name" | cut -d: -f2 | xargs)
        (( count++ ))
        nums+=("$num")
        echo -e "  ${GREEN}[$count]${R} /dev/disk${num}  ${BOLD}$size${R}  ${DIM}$name${R}"
    done < "$tmpfile"
    rm -f "$tmpfile"

    if (( count == 0 )); then
        echo -e "  ${RED}No external disks found.${R}"
        exit 1
    fi

    echo ""
    if (( count == 1 )); then
        DISK_NUM="${nums[0]}"
        echo -e "  ${CYAN}Auto-selected: /dev/disk${DISK_NUM}${R}"
    else
        echo -ne "  ${BOLD}Select [1-${count}]: ${R}"
        read -r choice
        if (( choice < 1 || choice > count )); then
            echo -e "  ${RED}Invalid selection.${R}"
            exit 1
        fi
        DISK_NUM="${nums[$((choice-1))]}"
    fi

    DISK="/dev/disk${DISK_NUM}"
    RDISK="/dev/rdisk${DISK_NUM}"

    echo -e "\n  ${YELLOW}Selected: ${BOLD}${RDISK}${R}\n"
    diskutil list "$DISK"
    echo ""
    echo -ne "  ${RED}${BOLD}ALL DATA WILL BE ERASED. Type 'yes': ${R}"
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "  ${DIM}Aborted.${R}"
        exit 0
    fi
}

check_resume() {
    echo -e "\n${BOLD}  Resume offset (MB):${R}"
    echo -e "  ${DIM}0 = start fresh, or enter MB offset to resume:${R}"
    echo -ne "  ${CYAN}Offset [0]: ${R}"
    read -r offset
    START_OFFSET="${offset:-0}"
    if (( START_OFFSET > 0 )); then
        echo -e "  ${YELLOW}Resuming from ${START_OFFSET}MB${R}"
    fi
}

configure_chunk_size() {
    echo -e "\n${BOLD}  Chunk size (MB):${R}"
    echo -e "  ${DIM}Smaller = more stable. Recommended: 10-25${R}"
    echo -ne "  ${CYAN}Chunk size [${CHUNK_MB}]: ${R}"
    read -r chunk
    CHUNK_MB="${chunk:-$CHUNK_MB}"
    echo -e "  ${GREEN}Chunk size: ${CHUNK_MB}MB${R}"
}

wait_for_reconnect() {
    local waited=0
    echo -ne "  ${YELLOW}Waiting for disk...${R}"
    while (( waited < 30 )); do
        sleep 1
        (( waited++ ))
        if diskutil list "$DISK" >/dev/null 2>&1; then
            echo -e " ${GREEN}back (${waited}s)${R}"
            sleep 2
            return 0
        fi
        echo -ne "."
    done
    echo -e " ${RED}timeout${R}"
    return 1
}

print_stats() {
    local cur=$1 elapsed=$2 spd=$3 spd_type=$4
    local pct=$(( IMG_SIZE_MB > 0 ? cur * 100 / IMG_SIZE_MB : 0 ))
    local remaining=$(( IMG_SIZE_MB - cur ))
    local eta="?"
    if [[ "$spd_type" == "real" ]] && (( $(echo "$spd > 0" | bc -l) )); then
        eta=$(format_time "$(echo "scale=0; $remaining / $spd" | bc)")
    fi

    echo -e "\n  ${BOLD}Progress:${R}"
    echo -e "  [${CYAN}$(progress_bar "$cur" "$IMG_SIZE_MB")${R}] ${BOLD}${pct}%${R}"
    echo -e "  ${GREEN}Written:${R}    ${cur}MB / ${IMG_SIZE_MB}MB"
    echo -e "  ${GREEN}Elapsed:${R}    $(format_time "$elapsed")"
    echo -e "  ${GREEN}ETA:${R}        $eta"
    echo -e "  ${GREEN}Speed:${R}      ${spd} MB/s ${DIM}(${spd_type})${R}"
    print_sep
    echo -e "  ${CYAN}Real:${R} $REAL_WRITES  ${DIM}Cached: $CACHE_HITS${R}  ${YELLOW}Retries: $TOTAL_RETRIES${R}  ${RED}Drops: $DROPS${R}"
    echo -e "  ${DIM}Log: $LOG_FILE${R}\n"
}

write_image() {
    local offset=$START_OFFSET
    local start_time
    start_time=$(date +%s)
    local last_speed="0"
    local last_speed_type="unknown"

    echo -e "\n${BOLD}${GREEN}  Starting write...${R}\n"
    log "START: IMG=$IMG DISK=$RDISK CHUNK=${CHUNK_MB}MB OFFSET=${offset}MB"

    while (( offset < IMG_SIZE_MB )); do
        local remaining=$(( IMG_SIZE_MB - offset ))
        local this_chunk=$(( remaining < CHUNK_MB ? remaining : CHUNK_MB ))
        local retries=0 chunk_done=0

        while (( retries < MAX_RETRIES && !chunk_done )); do
            diskutil unmountDisk "$DISK" >/dev/null 2>&1
            sleep 0.5

            local dd_output dd_exit bytes_written time_taken
            dd_output=$(sudo dd if="$IMG" of="$RDISK" bs=$BS count=$this_chunk skip=$offset seek=$offset 2>&1)
            dd_exit=$?
            bytes_written=$(echo "$dd_output" | grep "bytes transferred" | awk '{print $1}')
            time_taken=$(echo "$dd_output" | grep "bytes transferred" | awk '{print $5}')

            if (( dd_exit != 0 )) || echo "$dd_output" | grep -q "Device not configured\|Resource busy\|Input/output error"; then
                (( DROPS++ ))
                (( TOTAL_RETRIES++ ))
                (( retries++ ))
                local partial_mb=$(( ${bytes_written:-0} / 1048576 ))
                echo -e "  ${RED}Drop at ${offset}MB${R} ${DIM}(~${partial_mb}MB, retry ${retries}/${MAX_RETRIES})${R}"
                log "DROP offset=${offset}MB partial=${partial_mb}MB retry=${retries}"
                wait_for_reconnect || sleep $(( RETRY_DELAY * 2 ))
                sleep $RETRY_DELAY
                continue
            fi

            if [[ -n "$bytes_written" && -n "$time_taken" ]] && (( $(echo "$time_taken > 0" | bc -l) )); then
                last_speed=$(echo "scale=1; ($bytes_written / 1048576) / $time_taken" | bc)
                if (( $(echo "$last_speed > $CACHE_THRESHOLD" | bc -l) )); then
                    last_speed_type="cached"
                    (( CACHE_HITS++ ))
                    echo -e "  ${YELLOW}~ ${offset}MB${R}  ${this_chunk}MB @ ${last_speed} MB/s ${DIM}(cache)${R}"
                    log "CACHE offset=${offset}MB speed=${last_speed}MB/s"
                else
                    last_speed_type="real"
                    (( REAL_WRITES++ ))
                    echo -e "  ${GREEN}+ ${offset}MB${R}  ${this_chunk}MB @ ${last_speed} MB/s"
                    log "OK offset=${offset}MB speed=${last_speed}MB/s"
                fi
            else
                last_speed_type="real"
                (( REAL_WRITES++ ))
                echo -e "  ${GREEN}+ ${offset}MB${R}  ${this_chunk}MB"
            fi

            (( offset += this_chunk ))
            chunk_done=1

            if (( offset % 100 == 0 || offset >= IMG_SIZE_MB )); then
                print_stats "$offset" "$(( $(date +%s) - start_time ))" "$last_speed" "$last_speed_type"
            fi
        done

        if (( !chunk_done )); then
            (( FAILED_CHUNKS++ ))
            echo -e "  ${RED}CHUNK FAILED after $MAX_RETRIES retries at ${offset}MB — skipping${R}"
            log "SKIP offset=${offset}MB"
            (( offset += this_chunk ))
        fi
    done

    local total_elapsed=$(( $(date +%s) - start_time ))
    echo -e "\n${BOLD}${GREEN}  WRITE COMPLETE${R}\n"
    echo -e "  ${GREEN}Total time:${R}   $(format_time "$total_elapsed")"
    echo -e "  ${GREEN}Real writes:${R}  $REAL_WRITES chunks"
    echo -e "  ${YELLOW}Cache hits:${R}   $CACHE_HITS chunks"
    echo -e "  ${YELLOW}Retries:${R}      $TOTAL_RETRIES"
    echo -e "  ${RED}Drops:${R}        $DROPS"
    if (( FAILED_CHUNKS > 0 )); then
        echo -e "  ${RED}Failed:${R}       $FAILED_CHUNKS chunks (skipped)"
    fi
    echo -e "  ${DIM}Log: $LOG_FILE${R}\n"
    log "DONE elapsed=${total_elapsed}s real=$REAL_WRITES cached=$CACHE_HITS drops=$DROPS"

    echo -ne "  ${CYAN}Ejecting...${R}"
    if diskutil eject "$DISK" >/dev/null 2>&1; then
        echo -e " ${GREEN}Safe to remove.${R}"
    else
        echo -e " ${YELLOW}Eject manually.${R}"
    fi
}

offer_verify() {
    echo -ne "\n  ${BOLD}Verify first 512MB? [y/N]: ${R}"
    read -r v
    [[ "$v" != [yY] ]] && return
    echo -e "  ${CYAN}Verifying...${R}"
    local ih ch
    ih=$(dd if="$IMG" bs=1m count=512 2>/dev/null | md5)
    ch=$(dd if="$RDISK" bs=1m count=512 2>/dev/null | md5)
    if [[ "$ih" == "$ch" ]]; then
        echo -e "  ${GREEN}Verification passed.${R}"
    else
        echo -e "  ${RED}Verification FAILED.${R}"
    fi
}

main() {
    clear
    echo -e "${BOLD}${CYAN}  SD CARD IMAGE WRITER  v2.2"
    echo -e "  macOS / bash / ARM64${R}"
    print_sep

    if ! sudo -n true 2>/dev/null; then
        echo -e "  ${YELLOW}Sudo required.${R}"
        sudo -v || { echo -e "  ${RED}sudo failed${R}"; exit 1; }
    fi

    select_image
    print_sep
    select_disk
    print_sep
    check_resume
    configure_chunk_size
    print_sep

    echo -e "\n  ${BOLD}Summary:${R}"
    echo -e "  Image:  $(basename "$IMG") ($IMG_SIZE_HUMAN)"
    echo -e "  Disk:   $RDISK"
    echo -e "  Offset: ${START_OFFSET}MB"
    echo -e "  Chunks: ${CHUNK_MB}MB"
    echo -e "  Log:    $LOG_FILE"
    print_sep

    echo -ne "\n  ${BOLD}${GREEN}Press ENTER to start...${R}"
    read -r

    write_image
    offer_verify
}

main "$@"