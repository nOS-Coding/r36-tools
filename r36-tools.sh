#!/bin/zsh

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
R='\033[0m'

# ── Shared helpers ───────────────────────────────────────────

LOG_FILE="/tmp/r36s_$(date +%Y%m%d_%H%M%S).log"

log() { print "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" }

format_time() {
    local s=$1
    (( s < 0 )) && s=0
    local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    if   (( h > 0 )); then printf "%dh %02dm %02ds" $h $m $sec
    elif (( m > 0 )); then printf "%dm %02ds" $m $sec
    else printf "%ds" $sec
    fi
}

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

# ── Common disk/partition helpers (push + encode) ────────────

select_disk_push() {
    print "\n${BOLD}  Scanning for external disks...${R}\n"

    local tmpfile count nums num size name choice
    tmpfile=$(mktemp)
    diskutil list 2>/dev/null | grep "external" | awk '{print $1}' | sed 's|/dev/disk||' > "$tmpfile"

    count=0
    nums=()
    while IFS= read -r num; do
        [[ -z "$num" ]] && continue
        size=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Disk Size" | awk '{print $3, $4}')
        name=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Device / Media Name" | cut -d: -f2 | xargs)
        (( count++ ))
        nums+=("$num")
        print "  ${GREEN}[$count]${R} /dev/disk${num}  ${BOLD}$size${R}  ${DIM}$name${R}"
    done < "$tmpfile"
    rm -f "$tmpfile"

    (( count == 0 )) && { print "  ${RED}No external disks found.${R}"; exit 1 }

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

select_partition() {
    print "\n  Partitions on ${BOLD}${DISK}${R}:\n"
    diskutil list "$DISK"
    print ""
    printf "  ${BOLD}Partition slice (e.g. s8): ${R}"
    read -r slice
    [[ -z "$slice" ]] && { print "  ${RED}No partition selected.${R}"; exit 1 }
    PARTITION="$slice"
    diskutil info "${DISK}${PARTITION}" >/dev/null 2>&1 || \
        { print "  ${RED}${DISK}${PARTITION} not found.${R}"; exit 1 }
}

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

remount() {
    diskutil unmount "${DISK}${PARTITION}" >/dev/null 2>&1
    sleep $RETRY_DELAY
    diskutil mount "${DISK}${PARTITION}" >/dev/null 2>&1
    sleep 2
    local new_mp
    new_mp=$(diskutil info "${DISK}${PARTITION}" 2>/dev/null | grep "Mount Point" | cut -d: -f2 | xargs)
    [[ -n "$new_mp" && -d "$new_mp" ]] && MOUNT_POINT="$new_mp"
}

list_and_select_dest() {
    local src="$1"
    local src_name is_dir=0
    src_name=$(basename "$src")
    [[ -d "$src" ]] && is_dir=1

    print "\n${BOLD}  Destination for: ${CYAN}${src_name}${R}"
    print "  ${DIM}Listing $MOUNT_POINT:${R}\n"

    local tmpfile idx entry rel choice dest
    tmpfile=$(mktemp)

    print "  ${GREEN}[0]${R} ${BOLD}/ (partition root)${R}  =>  $MOUNT_POINT"
    print "$MOUNT_POINT" >> "$tmpfile"

    idx=0
    while IFS= read -r entry; do
        [[ ! -d "$entry" ]] && continue
        (( idx++ ))
        rel="${entry#$MOUNT_POINT/}"
        printf "  ${GREEN}[%d]${R} /%s\n" $idx "$rel"
        print "$entry" >> "$tmpfile"
    done < <(find "$MOUNT_POINT" -mindepth 1 -maxdepth 2 -type d | sort)

    print ""
    if (( is_dir )); then
        print "  ${DIM}Folder => placed inside chosen location. Overwrites if exists.${R}"
    else
        print "  ${DIM}File => placed directly into chosen location.${R}"
    fi
    print ""
    printf "  ${BOLD}Select [0-%d]: ${R}" $idx
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > idx )); then
        print "  ${RED}Invalid selection.${R}"
        rm -f "$tmpfile"
        exit 1
    fi

    dest=$(sed -n "$((choice+1))p" "$tmpfile")
    rm -f "$tmpfile"

    [[ -z "$dest" ]] && { print "  ${RED}Could not resolve destination.${R}"; exit 1 }

    if (( is_dir )) && [[ -d "$dest/$src_name" ]]; then
        print "  ${YELLOW}'$src_name' exists at destination -- will overwrite.${R}"
    fi

    print "  ${GREEN}=> $dest${R}"
    DESTS+=("$dest")
}

# ═══════════════════════════════════════════════════════════════
#  TOOL 1: push  — copy files/folders to SD card
# ═══════════════════════════════════════════════════════════════

typeset -g DISK_NUM=""
typeset -g DISK=""
typeset -g PARTITION=""
typeset -g MOUNT_POINT=""
typeset -ga SOURCES
typeset -ga DESTS
typeset -g MAX_RETRIES=8
typeset -g RETRY_DELAY=5
typeset -g CACHE_THRESHOLD=50
typeset -g GRAND_START=0

draw_push_ui() {
    local task_name="$1" file_name="$2"
    local task_cur=$3 task_tot=$4 overall_cur=$5 overall_tot=$6
    local elapsed=$7 eta="$8"

    tput cup 0 0
    tput ed

    print "${BOLD}${CYAN}  R36S FILE PUSHING TOOL${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
    print ""
    printf "  ${BOLD}Current:${R}  %s\n" "$task_name"
    printf "  ${DIM}File:${R}     %s\n" "$file_name"
    print ""
    printf "  Task:    "
    progress_bar "$task_cur" "$task_tot"
    printf "  ${DIM}(%d / %d files)${R}\n" "$task_cur" "$task_tot"
    print ""
    printf "  Overall: "
    progress_bar "$overall_cur" "$overall_tot"
    printf "  ${DIM}(%d / %d entries)${R}\n" "$overall_cur" "$overall_tot"
    print ""
    printf "  ${GREEN}Elapsed:${R}  %s\n" "$(format_time $elapsed)"
    printf "  ${GREEN}ETA:${R}      %s\n" "$eta"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
}

select_sources() {
    print "\n${BOLD}  Source paths:${R}"
    print "  ${DIM}Enter files or folders one per line. Empty line when done.${R}\n"
    local idx=1
    while true; do
        printf "  ${CYAN}[%d] Path (empty to finish): ${R}" $idx
        read -r src
        src="${src//\'/}"
        src="${src//\\ / }"
        [[ -z "$src" ]] && break
        if [[ ! -e "$src" ]]; then
            print "  ${RED}Not found: $src${R}"
            continue
        fi
        SOURCES+=("$src")
        if [[ -d "$src" ]]; then
            local count size
            count=$(find "$src" -type f | wc -l | xargs)
            size=$(du -sh "$src" 2>/dev/null | awk '{print $1}')
            print "  ${GREEN}Folder:${R} $(basename $src)  ${DIM}($count files, $size)${R}"
        else
            local size
            size=$(stat -f%z "$src" 2>/dev/null)
            print "  ${GREEN}File:${R} $(basename $src)  ${DIM}($size bytes)${R}"
        fi
        (( idx++ ))
    done
    (( ${#SOURCES[@]} == 0 )) && { print "  ${RED}No sources provided.${R}"; exit 1 }
}

copy_entry() {
    local src="$1" dest="$2" overall_cur=$3 overall_tot=$4
    local src_name filelist file_tot file_cur filepath fname retries
    local success ft0 ft1 fbytes fspeed fdur now elapsed eta_secs eta_str
    src_name=$(basename "$src")

    filelist=$(mktemp)
    file_tot=1

    if [[ -d "$src" ]]; then
        find "$src" -type f | sort > "$filelist"
        file_tot=$(wc -l < "$filelist" | xargs)
        [[ -d "$dest/$src_name" ]] && { log "Removing existing: $dest/$src_name"; rm -rf "$dest/$src_name" }
        mkdir -p "$dest/$src_name" 2>/dev/null
    else
        print "$src" > "$filelist"
    fi

    file_cur=0

    while IFS= read -r filepath; do
        fname=$(basename "$filepath")
        retries=0
        success=0

        local file_dest
        if [[ -d "$src" ]]; then
            local rel="${filepath#$src/}"
            mkdir -p "$dest/$src_name/$(dirname $rel)" 2>/dev/null
            file_dest="$dest/$src_name/$rel"
        else
            file_dest="$dest/$fname"
        fi

        while (( retries < MAX_RETRIES && !success )); do
            now=$(date +%s)
            elapsed=$(( now - GRAND_START ))
            eta_secs=0
            if (( file_cur > 0 && elapsed > 0 )); then
                local rate=$(( file_cur * 100 / elapsed ))
                local remaining=$(( file_tot - file_cur ))
                (( rate > 0 )) && eta_secs=$(( remaining * 100 / rate ))
            fi
            eta_str=$(format_time $eta_secs)

            draw_push_ui "$src_name" "$fname" \
                "$file_cur" "$file_tot" \
                "$overall_cur" "$overall_tot" \
                "$elapsed" "$eta_str"

            ft0=$(date +%s)
            cp "$filepath" "$file_dest" 2>/dev/null
            local rc=$?
            ft1=$(date +%s)
            fbytes=$(stat -f%z "$filepath" 2>/dev/null || print 0)
            fdur=$(( ft1 - ft0 ))
            fspeed=0
            (( fdur > 0 )) && fspeed=$(( fbytes / 1048576 / fdur ))

            if (( rc == 0 )); then
                (( fspeed > CACHE_THRESHOLD )) && log "CACHE? $fname @ ${fspeed}MB/s" || log "OK: $fname @ ${fspeed}MB/s"
                success=1
                (( file_cur++ ))
            else
                (( retries++ ))
                log "RETRY $retries: $fname"
                remount
            fi
        done

        (( !success )) && log "FAILED: $fname after $MAX_RETRIES retries"

    done < "$filelist"
    rm -f "$filelist"

    log "DONE: $src_name"
}

tool_push() {
    clear
    print "${BOLD}${CYAN}  R36S FILE PUSHING TOOL${R}"
    print "  ${DIM}macOS / diskutil / zsh${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"

    SOURCES=()
    DESTS=()
    select_sources
    select_disk_push
    select_partition
    mount_partition

    print "\n${BOLD}  Select destinations:${R}"
    local i=1
    while (( i <= ${#SOURCES[@]} )); do
        list_and_select_dest "${SOURCES[$i]}"
        (( i++ ))
    done

    local overall_tot=${#SOURCES[@]}
    print "\n${BOLD}  Summary:${R}"
    i=1
    while (( i <= overall_tot )); do
        print "  ${CYAN}$(basename ${SOURCES[$i]})${R}  ${DIM}-> ${DESTS[$i]}${R}"
        (( i++ ))
    done

    print ""
    printf "  ${BOLD}${GREEN}Press ENTER to start...${R}"
    read -r

    tput civis 2>/dev/null
    clear

    GRAND_START=$(date +%s)
    local overall_cur=0

    i=1
    while (( i <= overall_tot )); do
        (( overall_cur++ ))
        copy_entry "${SOURCES[$i]}" "${DESTS[$i]}" "$overall_cur" "$overall_tot"
        (( i++ ))
    done

    local total_elapsed=$(( $(date +%s) - GRAND_START ))
    tput cnorm 2>/dev/null
    clear
    print "${BOLD}${CYAN}  R36S FILE PUSHING TOOL - Done${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
    print ""
    print "  ${GREEN}Entries:${R}  $overall_tot"
    print "  ${GREEN}Time:${R}     $(format_time $total_elapsed)"
    print "  ${DIM}Log:      $LOG_FILE${R}"
    print ""
    log "COMPLETE: $overall_tot entries in $(format_time $total_elapsed)"
}


# ═══════════════════════════════════════════════════════════════
#  TOOL 2: write  — write .img to SD card via dd
# ═══════════════════════════════════════════════════════════════

typeset -g IMG=""
typeset -g IMG_SIZE=0
typeset -g IMG_SIZE_MB=0
typeset -g IMG_SIZE_HUMAN=""
typeset -g START_OFFSET=0
typeset -g TOTAL_RETRIES=0
typeset -g CACHE_HITS=0
typeset -g REAL_WRITES=0
typeset -g FAILED_CHUNKS=0
typeset -g DROPS=0
typeset -g CHUNK_MB=10
typeset -g WRITE_BS=1048576
typeset -g WRITE_MAX_RETRIES=10
typeset -g WRITE_RETRY_DELAY=5
typeset -g WRITE_CACHE_THRESHOLD=50
typeset -g RDISK=""

select_image() {
    print "\n${BOLD}  Image file:${R}"
    print "  ${DIM}Drag and drop your .img or type the full path:${R}"
    printf "  ${CYAN}Path: ${R}"
    read -r IMG
    IMG="${IMG//\'/}"
    IMG="${IMG//\\ / }"

    if [[ ! -f "$IMG" ]]; then
        print "  ${RED}File not found: $IMG${R}"
        exit 1
    fi

    IMG_SIZE=$(stat -f%z "$IMG")
    IMG_SIZE_MB=$(( IMG_SIZE / 1048576 ))
    IMG_SIZE_HUMAN=$(format_bytes "$IMG_SIZE")

    print "  ${GREEN}Found:${R} $(basename "$IMG")"
    print "  ${GREEN}Size:${R}  $IMG_SIZE_HUMAN ($IMG_SIZE_MB MB)"
}

select_disk_write() {
    print "\n${BOLD}  Scanning for external disks...${R}\n"

    local tmpfile count nums num size name choice
    tmpfile=$(mktemp)
    diskutil list 2>/dev/null | grep "external" | awk '{print $1}' | sed 's|/dev/disk||' > "$tmpfile"

    count=0
    nums=()
    while IFS= read -r num; do
        [[ -z "$num" ]] && continue
        size=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Disk Size" | awk '{print $3, $4}')
        name=$(diskutil info "/dev/disk${num}" 2>/dev/null | grep "Device / Media Name" | cut -d: -f2 | xargs)
        (( count++ ))
        nums+=("$num")
        print "  ${GREEN}[$count]${R} /dev/disk${num}  ${BOLD}$size${R}  ${DIM}$name${R}"
    done < "$tmpfile"
    rm -f "$tmpfile"

    if (( count == 0 )); then
        print "  ${RED}No external disks found.${R}"
        exit 1
    fi

    print ""
    if (( count == 1 )); then
        DISK_NUM="${nums[1]}"
        print "  ${CYAN}Auto-selected: /dev/disk${DISK_NUM}${R}"
    else
        printf "  ${BOLD}Select [1-%d]: ${R}" $count
        read -r choice
        if (( choice < 1 || choice > count )); then
            print "  ${RED}Invalid selection.${R}"
            exit 1
        fi
        DISK_NUM="${nums[$choice]}"
    fi

    DISK="/dev/disk${DISK_NUM}"
    RDISK="/dev/rdisk${DISK_NUM}"

    print "\n  ${YELLOW}Selected: ${BOLD}${RDISK}${R}\n"
    diskutil list "$DISK"
    print ""
    printf "  ${RED}${BOLD}ALL DATA WILL BE ERASED. Type 'yes': ${R}"
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        print "  ${DIM}Aborted.${R}"
        exit 0
    fi
}

check_resume() {
    print "\n${BOLD}  Resume offset (MB):${R}"
    print "  ${DIM}0 = start fresh, or enter MB offset to resume:${R}"
    printf "  ${CYAN}Offset [0]: ${R}"
    read -r offset
    START_OFFSET="${offset:-0}"
    if (( START_OFFSET > 0 )); then
        print "  ${YELLOW}Resuming from ${START_OFFSET}MB${R}"
    fi
}

configure_chunk_size() {
    print "\n${BOLD}  Chunk size (MB):${R}"
    print "  ${DIM}Smaller = more stable. Recommended: 10-25${R}"
    printf "  ${CYAN}Chunk size [${CHUNK_MB}]: ${R}"
    read -r chunk
    CHUNK_MB="${chunk:-$CHUNK_MB}"
    print "  ${GREEN}Chunk size: ${CHUNK_MB}MB${R}"
}

wait_for_reconnect() {
    local waited=0
    printf "  ${YELLOW}Waiting for disk...${R}"
    while (( waited < 30 )); do
        sleep 1
        (( waited++ ))
        if diskutil list "$DISK" >/dev/null 2>&1; then
            print " ${GREEN}back (${waited}s)${R}"
            sleep 2
            return 0
        fi
        printf "."
    done
    print " ${RED}timeout${R}"
    return 1
}

print_write_stats() {
    local cur=$1 elapsed=$2 spd=$3 spd_type=$4
    local pct=0
    (( IMG_SIZE_MB > 0 )) && pct=$(( cur * 100 / IMG_SIZE_MB ))
    local remaining=$(( IMG_SIZE_MB - cur ))
    local eta="?"
    if [[ "$spd_type" == "real" ]] && (( $(echo "$spd > 0" | bc -l) )); then
        eta=$(format_time "$(echo "scale=0; $remaining / $spd" | bc)")
    fi

    print "\n  ${BOLD}Progress:${R}"
    printf "  [${CYAN}"
    progress_bar "$cur" "$IMG_SIZE_MB"
    printf "${R}] ${BOLD}${pct}%%${R}\n"
    print "  ${GREEN}Written:${R}    ${cur}MB / ${IMG_SIZE_MB}MB"
    print "  ${GREEN}Elapsed:${R}    $(format_time "$elapsed")"
    print "  ${GREEN}ETA:${R}        $eta"
    print "  ${GREEN}Speed:${R}      ${spd} MB/s ${DIM}(${spd_type})${R}"
    print "  ${DIM}────────────────────────────────────────────────────────${R}"
    print "  ${CYAN}Real:${R} $REAL_WRITES  ${DIM}Cached: $CACHE_HITS${R}  ${YELLOW}Retries: $TOTAL_RETRIES${R}  ${RED}Drops: $DROPS${R}"
    print "  ${DIM}Log: $LOG_FILE${R}\n"
}

write_image() {
    local offset=$START_OFFSET
    local start_time last_speed last_speed_type
    start_time=$(date +%s)
    last_speed="0"
    last_speed_type="unknown"

    print "\n${BOLD}${GREEN}  Starting write...${R}\n"
    log "START: IMG=$IMG DISK=$RDISK CHUNK=${CHUNK_MB}MB OFFSET=${offset}MB"

    while (( offset < IMG_SIZE_MB )); do
        local remaining=$(( IMG_SIZE_MB - offset ))
        local this_chunk=$(( remaining < CHUNK_MB ? remaining : CHUNK_MB ))
        local retries=0 chunk_done=0

        while (( retries < WRITE_MAX_RETRIES && !chunk_done )); do
            diskutil unmountDisk "$DISK" >/dev/null 2>&1
            sleep 0.5

            local dd_output dd_exit bytes_written time_taken
            dd_output=$(sudo dd if="$IMG" of="$RDISK" bs=$WRITE_BS count=$this_chunk skip=$offset seek=$offset 2>&1)
            dd_exit=$?
            bytes_written=$(echo "$dd_output" | grep "bytes transferred" | awk '{print $1}')
            time_taken=$(echo "$dd_output" | grep "bytes transferred" | awk '{print $5}')

            if (( dd_exit != 0 )) || echo "$dd_output" | grep -q "Device not configured\|Resource busy\|Input/output error"; then
                (( DROPS++ ))
                (( TOTAL_RETRIES++ ))
                (( retries++ ))
                local partial_mb=$(( ${bytes_written:-0} / 1048576 ))
                print "  ${RED}Drop at ${offset}MB${R} ${DIM}(~${partial_mb}MB, retry ${retries}/${WRITE_MAX_RETRIES})${R}"
                log "DROP offset=${offset}MB partial=${partial_mb}MB retry=${retries}"
                wait_for_reconnect || sleep $(( WRITE_RETRY_DELAY * 2 ))
                sleep $WRITE_RETRY_DELAY
                continue
            fi

            if [[ -n "$bytes_written" && -n "$time_taken" ]] && (( $(echo "$time_taken > 0" | bc -l) )); then
                last_speed=$(echo "scale=1; ($bytes_written / 1048576) / $time_taken" | bc)
                if (( $(echo "$last_speed > $WRITE_CACHE_THRESHOLD" | bc -l) )); then
                    last_speed_type="cached"
                    (( CACHE_HITS++ ))
                    print "  ${YELLOW}~ ${offset}MB${R}  ${this_chunk}MB @ ${last_speed} MB/s ${DIM}(cache)${R}"
                    log "CACHE offset=${offset}MB speed=${last_speed}MB/s"
                else
                    last_speed_type="real"
                    (( REAL_WRITES++ ))
                    print "  ${GREEN}+ ${offset}MB${R}  ${this_chunk}MB @ ${last_speed} MB/s"
                    log "OK offset=${offset}MB speed=${last_speed}MB/s"
                fi
            else
                last_speed_type="real"
                (( REAL_WRITES++ ))
                print "  ${GREEN}+ ${offset}MB${R}  ${this_chunk}MB"
            fi

            (( offset += this_chunk ))
            chunk_done=1

            if (( offset % 100 == 0 || offset >= IMG_SIZE_MB )); then
                print_write_stats "$offset" "$(( $(date +%s) - start_time ))" "$last_speed" "$last_speed_type"
            fi
        done

        if (( !chunk_done )); then
            (( FAILED_CHUNKS++ ))
            print "  ${RED}CHUNK FAILED after $WRITE_MAX_RETRIES retries at ${offset}MB - skipping${R}"
            log "SKIP offset=${offset}MB"
            (( offset += this_chunk ))
        fi
    done

    local total_elapsed=$(( $(date +%s) - start_time ))
    print "\n${BOLD}${GREEN}  WRITE COMPLETE${R}\n"
    print "  ${GREEN}Total time:${R}   $(format_time "$total_elapsed")"
    print "  ${GREEN}Real writes:${R}  $REAL_WRITES chunks"
    print "  ${YELLOW}Cache hits:${R}   $CACHE_HITS chunks"
    print "  ${YELLOW}Retries:${R}      $TOTAL_RETRIES"
    print "  ${RED}Drops:${R}        $DROPS"
    if (( FAILED_CHUNKS > 0 )); then
        print "  ${RED}Failed:${R}       $FAILED_CHUNKS chunks (skipped)"
    fi
    print "  ${DIM}Log: $LOG_FILE${R}\n"
    log "DONE elapsed=${total_elapsed}s real=$REAL_WRITES cached=$CACHE_HITS drops=$DROPS"

    printf "  ${CYAN}Ejecting...${R}"
    if diskutil eject "$DISK" >/dev/null 2>&1; then
        print " ${GREEN}Safe to remove.${R}"
    else
        print " ${YELLOW}Eject manually.${R}"
    fi
}

offer_verify() {
    printf "\n  ${BOLD}Verify first 512MB? [y/N]: ${R}"
    read -r v
    [[ "$v" != [yY] ]] && return
    print "  ${CYAN}Verifying...${R}"
    local ih ch
    ih=$(dd if="$IMG" bs=1m count=512 2>/dev/null | md5)
    ch=$(dd if="$RDISK" bs=1m count=512 2>/dev/null | md5)
    if [[ "$ih" == "$ch" ]]; then
        print "  ${GREEN}Verification passed.${R}"
    else
        print "  ${RED}Verification FAILED.${R}"
    fi
}

tool_write() {
    clear
    print "${BOLD}${CYAN}  SD CARD IMAGE WRITER  v2.2${R}"
    print "  ${DIM}macOS / zsh / dd${R}"
    print "  ${DIM}────────────────────────────────────────────────────────────────${R}"

    if ! sudo -n true 2>/dev/null; then
        print "  ${YELLOW}Sudo required.${R}"
        sudo -v || { print "  ${RED}sudo failed${R}"; exit 1; }
    fi

    select_image
    print "  ${DIM}────────────────────────────────────────────────────────────────${R}"
    select_disk_write
    print "  ${DIM}────────────────────────────────────────────────────────────────${R}"
    check_resume
    configure_chunk_size
    print "  ${DIM}────────────────────────────────────────────────────────────────${R}"

    print "\n  ${BOLD}Summary:${R}"
    print "  Image:  $(basename "$IMG") ($IMG_SIZE_HUMAN)"
    print "  Disk:   $RDISK"
    print "  Offset: ${START_OFFSET}MB"
    print "  Chunks: ${CHUNK_MB}MB"
    print "  Log:    $LOG_FILE"
    print "  ${DIM}────────────────────────────────────────────────────────────────${R}"

    printf "\n  ${BOLD}${GREEN}Press ENTER to start...${R}"
    read -r

    write_image
    offer_verify
}


# ═══════════════════════════════════════════════════════════════
#  TOOL 3: encode  — re-encode media for R36S, push to card
# ═══════════════════════════════════════════════════════════════

typeset -g INPUT_FILE=""
typeset -g OUTPUT_FILE=""
typeset -g ENC_CACHE_THRESHOLD=50
typeset -g ENC_MAX_RETRIES=8
typeset -g ENC_RETRY_DELAY=5

draw_encode_ui() {
    local stage="$1" file_name="$2"
    local pct_num=$3 pct_tot=$4 elapsed=$5 eta="$6"
    local extra="$7"

    tput cup 0 0
    tput ed

    print "${BOLD}${CYAN}  R36S MEDIA ENCODER${R}"
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

check_deps() {
    local missing=()
    for cmd in ffmpeg ffprobe diskutil; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        print "  ${RED}Missing: ${missing[*]}${R}"
        print "  ${DIM}Install ffmpeg:  brew install ffmpeg${R}"
        exit 1
    fi
}

audio_encoder_flags() {
    if ffmpeg -encoders 2>/dev/null | grep -q libfdk_aac; then
        print -- "-c:a libfdk_aac -vbr 3"
    else
        print -- "-c:a aac -q:a 2"
    fi
}

select_source() {
    print "\n${BOLD}  Source file:${R}"
    print "  ${DIM}Enter the full path to your MP3 or MP4 file.${R}\n"
    printf "  ${CYAN}Path: ${R}"
    read -r INPUT_FILE
    INPUT_FILE="${INPUT_FILE//\'/}"
    INPUT_FILE="${INPUT_FILE//\\ / }"

    [[ ! -f "$INPUT_FILE" ]] && { print "  ${RED}Not found: $INPUT_FILE${R}"; exit 1 }

    local ext="${INPUT_FILE:e:l}"
    if [[ "$ext" != "mp4" && "$ext" != "mp3" ]]; then
        print "  ${RED}Unsupported type '.${ext}'. Only MP3 and MP4 are supported.${R}"
        exit 1
    fi

    local bytes
    bytes=$(stat -f%z "$INPUT_FILE" 2>/dev/null || print 0)
    print "  ${GREEN}File:${R} $(basename $INPUT_FILE)  ${DIM}($bytes bytes)${R}"
    log "SOURCE: $INPUT_FILE ($bytes bytes)"
}

select_dest() {
    local out_name
    out_name=$(basename "$OUTPUT_FILE")

    print "\n${BOLD}  Destination for: ${CYAN}${out_name}${R}"
    print "  ${DIM}Listing $MOUNT_POINT:${R}\n"

    local tmpfile idx entry rel choice dest
    tmpfile=$(mktemp)

    print "  ${GREEN}[0]${R} ${BOLD}/ (partition root)${R}  =>  $MOUNT_POINT"
    print "$MOUNT_POINT" >> "$tmpfile"

    idx=0
    while IFS= read -r entry; do
        [[ ! -d "$entry" ]] && continue
        (( idx++ ))
        rel="${entry#$MOUNT_POINT/}"
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

    dest=$(sed -n "$((choice+1))p" "$tmpfile")
    rm -f "$tmpfile"

    [[ -z "$dest" ]] && { print "  ${RED}Could not resolve destination.${R}"; exit 1 }

    OUTPUT_FILE="${dest}/$(basename $OUTPUT_FILE)"

    if [[ -f "$OUTPUT_FILE" ]]; then
        print "  ${YELLOW}'$(basename $OUTPUT_FILE)' already exists - will overwrite.${R}"
    fi

    print "  ${GREEN}=> $dest${R}"
    log "DEST: $OUTPUT_FILE"
}

run_encode() {
    local src="$1" dst_tmp="$2" type="$3"
    local aenc fname duration encode_start extra
    aenc=$(audio_encoder_flags)
    fname=$(basename "$src")
    extra=""

    duration=$(ffprobe -v quiet -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null || print 0)
    duration=${duration%.*}
    (( duration < 1 )) && duration=1

    encode_start=$(date +%s)

    tput civis 2>/dev/null
    clear

    if [[ "$type" == "mp4" ]]; then
        extra="H.264 Main . 640x480 . 30fps . CRF23 . AAC 128k"
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
                draw_encode_ui "Encoding (${type:u})" "$fname" \
                    "$done_s" "$duration" \
                    "$elapsed" "$(format_time $eta_s)" "$extra"
            fi
        done
    else
        extra="AAC-LC . 44100 Hz . stereo . 192 kbps -> .m4a"
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
                draw_encode_ui "Encoding (${type:u})" "$fname" \
                    "$done_s" "$duration" \
                    "$elapsed" "$(format_time $eta_s)" "$extra"
            fi
        done
    fi

    local total_elapsed=$(( $(date +%s) - encode_start ))
    draw_encode_ui "Encoding (${type:u})" "$fname" \
        "$duration" "$duration" \
        "$total_elapsed" "0s" "$extra"

    tput cnorm 2>/dev/null
    log "ENCODED: $src -> $dst_tmp in $(format_time $total_elapsed)"
}

copy_to_card() {
    local src="$1" dst="$2"
    local fname fbytes retries success
    local copy_start now elapsed ft0 ft1 fdur fspeed rc
    fname=$(basename "$src")
    fbytes=$(stat -f%z "$src" 2>/dev/null || print 0)
    retries=0
    success=0

    copy_start=$(date +%s)

    tput civis 2>/dev/null
    clear

    while (( retries < ENC_MAX_RETRIES && !success )); do
        now=$(date +%s)
        elapsed=$(( now - copy_start ))

        draw_encode_ui "Copying to SD card" "$fname" \
            "0" "1" \
            "$elapsed" "..." \
            "Attempt $((retries+1)) of $ENC_MAX_RETRIES"

        ft0=$(date +%s)
        cp "$src" "$dst" 2>/dev/null
        rc=$?
        ft1=$(date +%s)
        fdur=$(( ft1 - ft0 ))
        fspeed=0
        (( fdur > 0 )) && fspeed=$(( fbytes / 1048576 / fdur ))

        if (( rc == 0 )); then
            success=1
            (( fspeed > ENC_CACHE_THRESHOLD )) && \
                log "CACHE? $fname @ ${fspeed}MB/s" || \
                log "OK: $fname @ ${fspeed}MB/s"
            elapsed=$(( $(date +%s) - copy_start ))
            draw_encode_ui "Copying to SD card" "$fname" \
                "1" "1" \
                "$elapsed" "0s" \
                "${fspeed}MB/s"
        else
            (( retries++ ))
            log "RETRY $retries: $fname"
            draw_encode_ui "Copying to SD card - RETRYING" "$fname" \
                "0" "1" "$elapsed" "..." \
                "Retry $retries/$ENC_MAX_RETRIES - remounting..."
            remount
        fi
    done

    tput cnorm 2>/dev/null

    if (( !success )); then
        log "FAILED: $fname after $ENC_MAX_RETRIES retries"
        print "\n  ${RED}Copy failed after $ENC_MAX_RETRIES retries. Check log: $LOG_FILE${R}\n"
        exit 1
    fi
}

tool_encode() {
    clear
    print "${BOLD}${CYAN}  R36S MEDIA ENCODER${R}"
    print "  ${DIM}macOS / diskutil / zsh / ffmpeg${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"

    check_deps

    select_source

    local ext="${INPUT_FILE:e:l}"
    local base="${INPUT_FILE:t:r}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if [[ "$ext" == "mp4" ]]; then
        OUTPUT_FILE="${tmp_dir}/${base}_r36s.mp4"
    else
        OUTPUT_FILE="${tmp_dir}/${base}_r36s.m4a"
    fi

    select_disk_push
    select_partition
    mount_partition
    select_dest

    print "\n${BOLD}  Summary:${R}"
    print "  ${CYAN}Source:${R}  $INPUT_FILE"
    print "  ${CYAN}Encode:${R}  $(basename $OUTPUT_FILE)  ${DIM}(temp: $tmp_dir)${R}"
    print "  ${CYAN}Target:${R}  $OUTPUT_FILE"
    print ""
    printf "  ${BOLD}${GREEN}Press ENTER to encode + push...${R}"
    read -r

    GRAND_START=$(date +%s)
    log "START: $INPUT_FILE -> $OUTPUT_FILE"

    local tmp_out="${tmp_dir}/$(basename $OUTPUT_FILE)"
    run_encode "$INPUT_FILE" "$tmp_out" "$ext"

    [[ ! -f "$tmp_out" ]] && { print "\n  ${RED}Encoding failed.${R}\n"; exit 1 }

    copy_to_card "$tmp_out" "$OUTPUT_FILE"

    rm -f "$tmp_out"
    rmdir "$tmp_dir" 2>/dev/null

    local total_elapsed=$(( $(date +%s) - GRAND_START ))
    clear
    print "${BOLD}${CYAN}  R36S MEDIA ENCODER - Done${R}"
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

    log "COMPLETE: $(basename $OUTPUT_FILE) - $(format_time $total_elapsed)"
}


# ═══════════════════════════════════════════════════════════════
#  MAIN DISPATCH
# ═══════════════════════════════════════════════════════════════

main() {
    local cmd="$1"

    if [[ -z "$cmd" ]]; then
        while true; do
            clear
            print "${BOLD}${CYAN}  R36S TOOLS${R}"
            print "  ${DIM}────────────────────────────────────────${R}"
            print ""
            print "   1)  SDCopy   Copy files/folders to SD card partition"
            print "   2)  SDWrite  Write .img to SD card via dd"
            print "   3)  MPEncode Re-encode media for R36S + push to card"
            print ""
            print "   0)  Exit"
            print ""
            printf "  ${BOLD}Select: ${R}"
            read -r choice
            case "$choice" in
                1) tool_push ;;
                2) tool_write ;;
                3) tool_encode ;;
                0) print "  ${DIM}Exiting.${R}"; break ;;
                *) print "  ${RED}Invalid.${R}" ;;
            esac
            print ""
            printf "  ${DIM}Press enter to continue...${R}"
            read -r
        done
        exit 0
    fi

    case "$cmd" in
        push|--push)   tool_push ;;
        write|--write) tool_write ;;
        encode|--encode) tool_encode ;;
        *)
            print "  ${RED}Unknown command: $cmd${R}"
            print "  ${DIM}Use: $SCRIPT_NAME push | write | encode${R}"
            exit 1
            ;;
    esac
}

# $0 in zsh functions is the function name, capture it before calling main
typeset -g SCRIPT_NAME="${0##*/}"
main "$@"
