#!/bin/zsh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
R='\033[0m'

typeset -g DISK_NUM=""
typeset -g DISK=""
typeset -g PARTITION=""
typeset -g MOUNT_POINT=""
typeset -ga SOURCES
typeset -ga DESTS
typeset -g MAX_RETRIES=8
typeset -g RETRY_DELAY=5
typeset -g CACHE_THRESHOLD=50
typeset -g LOG_FILE="/tmp/cpush_$(date +%Y%m%d_%H%M%S).log"
typeset -g GRAND_START=0

log() { print "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" }

format_time() {
    local s=$1
    (( s < 0 )) && s=0
    local h=$(( s/3600 )) m=$(( (s%3600)/60 )) sec=$(( s%60 ))
    if (( h > 0 )); then printf "%dh %02dm %02ds" $h $m $sec
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

draw_ui() {
    local task_name="$1"
    local file_name="$2"
    local task_cur=$3
    local task_tot=$4
    local overall_cur=$5
    local overall_tot=$6
    local elapsed=$7
    local eta="$8"

    tput cup 0 0
    tput ed

    print "${BOLD}${CYAN}  R36 FILE PUSHING TOOL${R}"
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
    diskutil info "${DISK}${PARTITION}" >/dev/null 2>&1 || { print "  ${RED}${DISK}${PARTITION} not found.${R}"; exit 1 }
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

list_and_select_dest() {
    local src="$1"
    local src_name
    src_name=$(basename "$src")
    local is_dir=0
    [[ -d "$src" ]] && is_dir=1

    print "\n${BOLD}  Destination for: ${CYAN}${src_name}${R}"
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

    local dest
    dest=$(sed -n "$((choice+1))p" "$tmpfile")
    rm -f "$tmpfile"

    [[ -z "$dest" ]] && { print "  ${RED}Could not resolve destination.${R}"; exit 1 }

    if (( is_dir )) && [[ -d "$dest/$src_name" ]]; then
        print "  ${YELLOW}'$src_name' exists at destination — will overwrite.${R}"
    fi

    print "  ${GREEN}=> $dest${R}"
    DESTS+=("$dest")
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

copy_entry() {
    local src="$1"
    local dest="$2"
    local overall_cur=$3
    local overall_tot=$4
    local src_name
    src_name=$(basename "$src")

    local filelist
    filelist=$(mktemp)
    local file_tot=1

    if [[ -d "$src" ]]; then
        find "$src" -type f | sort > "$filelist"
        file_tot=$(wc -l < "$filelist" | xargs)
        [[ -d "$dest/$src_name" ]] && { log "Removing existing: $dest/$src_name"; rm -rf "$dest/$src_name" }
        mkdir -p "$dest/$src_name" 2>/dev/null
    else
        print "$src" > "$filelist"
    fi

    local file_cur=0

    while IFS= read -r filepath; do
        local fname
        fname=$(basename "$filepath")
        local retries=0 success=0

        local file_dest
        if [[ -d "$src" ]]; then
            local rel="${filepath#$src/}"
            mkdir -p "$dest/$src_name/$(dirname $rel)" 2>/dev/null
            file_dest="$dest/$src_name/$rel"
        else
            file_dest="$dest/$fname"
        fi

        while (( retries < MAX_RETRIES && !success )); do
            local now elapsed eta_secs=0 eta_str
            now=$(date +%s)
            elapsed=$(( now - GRAND_START ))
            if (( file_cur > 0 && elapsed > 0 )); then
                local rate=$(( file_cur * 100 / elapsed ))
                local remaining=$(( file_tot - file_cur ))
                (( rate > 0 )) && eta_secs=$(( remaining * 100 / rate ))
            fi
            eta_str=$(format_time $eta_secs)

            draw_ui "$src_name" "$fname" \
                "$file_cur" "$file_tot" \
                "$overall_cur" "$overall_tot" \
                "$elapsed" "$eta_str"

            local ft0 ft1 fbytes fspeed=0
            ft0=$(date +%s)
            cp "$filepath" "$file_dest" 2>/dev/null
            local rc=$?
            ft1=$(date +%s)
            fbytes=$(stat -f%z "$filepath" 2>/dev/null || print 0)
            local fdur=$(( ft1 - ft0 ))
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

main() {
    clear
    print "${BOLD}${CYAN}  R36 FILE PUSHING TOOL${R}"
    print "  ${DIM}macOS / diskutil / zsh${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"

    select_sources
    select_disk
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
    print "${BOLD}${CYAN}  R36 FILE PUSHING TOOL — Done${R}"
    print "  ${DIM}────────────────────────────────────────────────────${R}"
    print ""
    print "  ${GREEN}Entries:${R}  $overall_tot"
    print "  ${GREEN}Time:${R}     $(format_time $total_elapsed)"
    print "  ${DIM}Log:      $LOG_FILE${R}"
    print ""
    log "COMPLETE: $overall_tot entries in $(format_time $total_elapsed)"
}

main "$@"
