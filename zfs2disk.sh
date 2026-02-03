#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS
# Version 3.1 - Safe Import & Safety Checks
#
# Aufruf: ./zfs2disk.sh <config_file>
#
# NEU IN V3.1:
# - Verbesserte Import-Logik (versucht Pfad-Import und Fallback).
# - Safety-Check mit 'zdb': Wenn ein Pool auf der Disk erkannt wird, aber nicht
#   importiert werden konnte, bricht das Skript ab, statt zu formatieren.

LOGFILE="/var/log/zfs2disk.log"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Error Handling Setup
set -o pipefail  # Return code of pipes is reflected
set -u           # Fail on unset variables

###############################################################################
# Konfiguration laden
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${1:-}" ]]; then
    echo "FEHLER: Keine Konfigurationsdatei angegeben."
    echo "Verwendung: $0 <konfigurationsdatei>"
    exit 1
fi

INPUT_CONFIG="$1"

if [[ -f "$INPUT_CONFIG" ]]; then
    CONFIG_FILE="$INPUT_CONFIG"
elif [[ -f "$SCRIPT_DIR/$INPUT_CONFIG" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/$INPUT_CONFIG"
else
    echo "FEHLER: Konfigurationsdatei '$INPUT_CONFIG' nicht gefunden." >&2
    exit 1
fi

source "$CONFIG_FILE"

# Defaults
BACKUP_MODE="${BACKUP_MODE:-full}"       # full oder latest
FORCE_FULL_WIPE="${FORCE_FULL_WIPE:-no}" # yes oder no
CHECKMK_EXPIRY_DAYS="${CHECKMK_EXPIRY_DAYS:-7}"

###############################################################################
# CheckMK & Logging Basics
###############################################################################
CHECKMK_SPOOL_DIR="/var/lib/check_mk_agent/spool"
HOSTNAME=$(hostname -f)
CONFIG_BASENAME=$(basename "$CONFIG_FILE")
SERVICE_NAME="${CONFIG_BASENAME%.*}"
STATUSFILE="/var/log/${SERVICE_NAME}_status"
SPOOL_FILE="${CHECKMK_SPOOL_DIR}/90000_${HOSTNAME}:${SERVICE_NAME}"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [$SERVICE_NAME] - $1" | tee -a "$LOGFILE"
}

set_status() {
    echo "LastStatus: $1"  > "$STATUSFILE"
    echo "LastMessage: $2" >> "$STATUSFILE"
}

create_checkmk_spool() {
    mkdir -p "$CHECKMK_SPOOL_DIR"
    EXPIRY_DATE=$(date -d "+$CHECKMK_EXPIRY_DAYS days" +'%Y-%m-%d')
    cat > "$SPOOL_FILE" << EOF
<<<local>>>
$1 $SERVICE_NAME - $2 (Valid until: $EXPIRY_DATE)
EOF
}

handle_error() {
    local msg="$1"
    local line="${2:-?}"
    log "FEHLER (Zeile $line): $msg"
    set_status 2 "$msg"
    create_checkmk_spool 2 "$msg"

    if zpool list "$POOL_NAME" &>/dev/null; then
        log "Not-Export des Pools..."
        zpool export "$POOL_NAME" || true
    fi
    exit 1
}

trap 'handle_error "Unerwarteter Abbruch des Skripts" $LINENO' ERR

###############################################################################
# Dataset-Ausschlussfunktion
###############################################################################
is_excluded() {
    local ds="$1"
    if [ -z "${EXCLUDE_DATASETS+x}" ]; then return 1; fi
    for ex in "${EXCLUDE_DATASETS[@]}"; do
        if [[ "$ds" == "$ex" ]]; then return 0; fi
    done
    return 1
}

###############################################################################
# Backup beginnt
###############################################################################
log "##### Backup-Prozess gestartet (Wipe: $FORCE_FULL_WIPE) #####"
create_checkmk_spool 1 "Backup läuft..."

###############################################################################
# 1. Externe Platte finden
###############################################################################
EXTERNAL_DEVICE=""
for serial in "${EXTERNAL_SERIALS[@]}"; do
    dev=$(ls /dev/disk/by-id/ | grep -E "^${serial}$" | head -n1 || true)
    if [[ -n "$dev" ]]; then
        EXTERNAL_DEVICE="$dev"
        log "Gefunden: /dev/disk/by-id/$dev"
        break
    fi
done
[[ -z "$EXTERNAL_DEVICE" ]] && handle_error "Keine externe Platte gefunden." $LINENO

###############################################################################
# 2. Pool Management (Safe Import)
###############################################################################
POOL_IMPORTED=0

# WIPE Check
if [[ "$FORCE_FULL_WIPE" == "yes" ]]; then
    if zpool list "$POOL_NAME" &>/dev/null; then
        log "FORCE WIPE: Zerstöre existierenden Pool '$POOL_NAME'..."
        zpool destroy "$POOL_NAME" || handle_error "Konnte Pool nicht zerstören." $LINENO
    fi
fi

# Import Versuch
if zpool list "$POOL_NAME" &>/dev/null; then
    log "Pool '$POOL_NAME' ist bereits importiert."
    POOL_IMPORTED=1
else
    log "Versuche Pool '$POOL_NAME' zu importieren..."
    
    # 1. Versuch: Spezifisch über Device-ID (Schnell & Sicher)
    if zpool import -d /dev/disk/by-id/ -f "$POOL_NAME" 2>/dev/null; then
        log "Import via /dev/disk/by-id erfolgreich."
        POOL_IMPORTED=1
    # 2. Versuch: Globaler Scan (Falls Device-Link anders ist)
    elif zpool import -f "$POOL_NAME" 2>/dev/null; then
        log "Import via Global Scan erfolgreich."
        POOL_IMPORTED=1
    else
        log "Import fehlgeschlagen."
    fi
fi

# Wenn nicht importiert: Prüfen ob wir formatieren DÜRFEN
if [[ "$POOL_IMPORTED" -eq 0 ]]; then
    
    # SAFETY CHECK: Prüfen, ob auf der Platte ein ZFS Label für diesen Pool existiert
    # zdb -l liest die ZFS Labels der Platte. Wenn dort der Name auftaucht, existiert der Pool,
    # konnte aber nicht importiert werden (z.B. Fehler, Version mismatch, etc.)
    if [[ "$FORCE_FULL_WIPE" == "no" ]]; then
        if zdb -l "/dev/disk/by-id/$EXTERNAL_DEVICE" | grep -q "name: '$POOL_NAME'"; then
            handle_error "ABBRUCH! Pool '$POOL_NAME' auf Disk gefunden, aber Import fehlgeschlagen. Überschreibe nicht ohne FORCE_FULL_WIPE='yes'." $LINENO
        fi
    fi

    log "Erstelle NEUEN Pool '$POOL_NAME' auf $EXTERNAL_DEVICE..."
    zpool create -f -o ashift=12 "$POOL_NAME" /dev/disk/by-id/"$EXTERNAL_DEVICE" \
        || handle_error "Pool konnte nicht erstellt werden." $LINENO
    zfs set com.sun:auto-snapshot=false "$POOL_NAME" || true
    log "Neuer Pool erstellt. (Initial Backup)"
fi

###############################################################################
# 3. VMs herunterfahren
###############################################################################
if [ ${#VM_IDS[@]} -gt 0 ]; then
    log "Fahre Maschinen herunter: ${VM_IDS[*]}"
    for vm in "${VM_IDS[@]}"; do
        if qm status "$vm" &>/dev/null; then
            state=$(qm status "$vm" | awk '{print $2}')
            [[ "$state" != "stopped" ]] && qm shutdown "$vm" && log "VM $vm Shutdown initiiert."
        elif pct status "$vm" &>/dev/null; then
            state=$(pct status "$vm" | awk -F": " '{print $2}')
            [[ "$state" != "stopped" ]] && pct shutdown "$vm" && log "LXC $vm Shutdown initiiert."
        fi
    done
    log "Warte $WAIT_AFTER_CRITICAL Sekunden auf Shutdown..."
    sleep "$WAIT_AFTER_CRITICAL"
fi

###############################################################################
# 4. Snapshots senden (Inkrementell Intelligent)
###############################################################################
log "Analysiere Datasets und synchronisiere..."

for SRC_ROOT in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$SRC_ROOT"; then continue; fi

    if ! zfs list -H -o name "$SRC_ROOT" >/dev/null 2>&1; then
        log "WARNUNG: Dataset '$SRC_ROOT' existiert nicht. Überspringe."
        continue
    fi

    ALL_DATASETS=$(zfs list -H -r -o name "$SRC_ROOT")

    for CURRENT_DS in $ALL_DATASETS; do
        if is_excluded "$CURRENT_DS"; then
            log "Überspringe Exclude: $CURRENT_DS"
            continue
        fi

        SNAPS_LIST=$(zfs list -H -t snapshot -o name -S creation -d 1 "$CURRENT_DS" 2>/dev/null)
        if [[ -z "$SNAPS_LIST" ]]; then continue; fi

        LATEST_SNAP=$(echo "$SNAPS_LIST" | head -n 1)
        OLDEST_SNAP=$(echo "$SNAPS_LIST" | tail -n 1)

        REL_PATH="${CURRENT_DS#*/}"
        DST="$POOL_NAME/$REL_PATH"

        DEST_EXISTS=0
        if zfs list "$DST" >/dev/null 2>&1; then DEST_EXISTS=1; else
            PARENT_DST="${DST%/*}"
            if [[ "$PARENT_DST" != "$POOL_NAME" ]]; then zfs create -p "$PARENT_DST" 2>/dev/null || true; fi
        fi

        if [[ "$DEST_EXISTS" -eq 0 ]]; then
            # Initiales Backup
            log "[INIT] Sende $CURRENT_DS komplett..."
            if [[ "$BACKUP_MODE" == "latest" && "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                 zfs send -w -p "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
            else
                 zfs send -w -p "$OLDEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                 if [[ "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                    zfs send -w -p -I "$OLDEST_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                 fi
            fi
        else
            # Inkrementelles Update
            LATEST_DEST_SNAP_FULL=$(zfs list -H -t snapshot -o name -S creation -d 1 "$DST" 2>/dev/null | head -n 1)
            
            if [[ -z "$LATEST_DEST_SNAP_FULL" ]]; then
                log "[FIX]  Ziel $DST existiert ohne Snapshots. Sende komplett neu."
                zfs send -w -p "$OLDEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                if [[ "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                    zfs send -w -p -I "$OLDEST_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                fi
                continue
            fi

            COMMON_SNAP_NAME="${LATEST_DEST_SNAP_FULL#*@}"
            COMMON_SNAP_SRC="${CURRENT_DS}@${COMMON_SNAP_NAME}"
            
            if zfs list -t snapshot "$COMMON_SNAP_SRC" >/dev/null 2>&1; then
                if [[ "$COMMON_SNAP_SRC" == "$LATEST_SNAP" ]]; then
                    log "[OK]   $DST ist aktuell."
                else
                    log "[INC]  Update $DST: @$COMMON_SNAP_NAME -> @${LATEST_SNAP#*@}"
                    if ! zfs send -w -p -I "$COMMON_SNAP_SRC" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                         log "[ERR]  Fehler beim inkrementellen Update. Siehe Log."
                    fi
                fi
            else
                log "[ERR]  Split-Brain bei $DST! Gemeinsamer Snapshot @$COMMON_SNAP_NAME fehlt auf Quelle."
            fi
        fi
    done
done

###############################################################################
# 5. VMs starten
###############################################################################
if [ ${#VM_IDS[@]} -gt 0 ]; then
    log "Starte Maschinen neu..."
    for vm in "${VM_IDS[@]}"; do
        if qm status "$vm" &>/dev/null; then
            qm start "$vm" || log "WARNUNG: Start fehlgeschlagen: VM $vm"
        elif pct status "$vm" &>/dev/null; then
            pct start "$vm" || log "WARNUNG: Start fehlgeschlagen: LXC $vm"
        fi
    done
fi

###############################################################################
# 6. Abschluss
###############################################################################
log "Exportiere Pool '$POOL_NAME'..."
zpool export "$POOL_NAME" || log "Warnung: Konnte Pool nicht exportieren."

log "##### Backup erfolgreich abgeschlossen #####"
set_status 0 "Backup erfolgreich"
create_checkmk_spool 0 "Backup erfolgreich."

trap - ERR 
exit 0
