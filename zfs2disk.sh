#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS
# Version 1.7 - Robust Snapshot Fetching
#
# Aufruf: ./zfs2disk.sh <config_file>
#
# ÄNDERUNG V1.7: 
# - Abfangen von Fehlern bei 'zfs list', damit das Skript nicht abbricht, 
#   wenn ein Dataset keine Snapshots hat oder nicht existiert.
# - Nutzt "zfs send -w" (Raw) für 1:1 Kopien (Encrypted/Compressed).

LOGFILE="/var/log/zfs2disk.log"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Error Handling Setup
set -o pipefail  # Return code of pipes is reflected
set -u           # Fail on unset variables

###############################################################################
# Konfiguration laden (Argument-basiert)
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
    cat > "$SPOOL_FILE" << EOF
<<<local>>>
$1 $SERVICE_NAME - $2 ($(date +'%Y-%m-%d %H:%M:%S'))
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
    # Prüft sicher, ob EXCLUDE_DATASETS gesetzt ist, bevor darauf zugegriffen wird
    if [ -z "${EXCLUDE_DATASETS+x}" ]; then return 1; fi
    
    for ex in "${EXCLUDE_DATASETS[@]}"; do
        if [[ "$ds" == "$ex" ]]; then return 0; fi
    done
    return 1
}

###############################################################################
# Backup beginnt
###############################################################################
log "##### Backup-Prozess gestartet (V1.7 Robust Mode) #####"
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
# 2. alten Pool entfernen
###############################################################################
if zpool list "$POOL_NAME" &>/dev/null; then
    log "Entferne alten Pool '$POOL_NAME'..."
    zpool destroy "$POOL_NAME" || handle_error "Pool konnte nicht zerstört werden." $LINENO
else
    log "Kein alter Pool vorhanden."
fi

###############################################################################
# 3. neuen Pool anlegen
###############################################################################
log "Erstelle neuen Pool '$POOL_NAME'..."
zpool create -f -o ashift=12 "$POOL_NAME" /dev/disk/by-id/"$EXTERNAL_DEVICE" \
    || handle_error "Pool konnte nicht erstellt werden." $LINENO

zfs set com.sun:auto-snapshot=false "$POOL_NAME" || true

###############################################################################
# 4. VMs herunterfahren
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
else
    log "Keine VMs zum Herunterfahren definiert."
fi

###############################################################################
# 5. Snapshots senden (Pass-Through Modus)
###############################################################################
log "Suche neueste Snapshots und übertrage..."

for SRC in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$SRC"; then
        continue
    fi
    
    # Check ob Dataset überhaupt existiert, sonst überspringen (verhindert Crash)
    if ! zfs list -H -o name "$SRC" >/dev/null 2>&1; then
        log "WARNUNG: Dataset '$SRC' existiert nicht. Überspringe."
        continue
    fi

    # 1. Neuesten Snapshot ermitteln (mit || true, damit pipefail nicht triggert wenn leer)
    LATEST_SNAP=$(zfs list -H -t snapshot -o name -S creation -d 1 "$SRC" 2>/dev/null | head -n 1 || true)

    if [[ -z "$LATEST_SNAP" ]]; then
        log "WARNUNG: Kein Snapshot für '$SRC' gefunden. Überspringe Dataset."
        continue
    fi

    REL_PATH="${SRC#*/}"
    DST="$POOL_NAME/$REL_PATH"

    PARENT_DST="${DST%/*}"
    if [[ "$PARENT_DST" != "$POOL_NAME" ]]; then
        zfs create -p "$PARENT_DST" 2>/dev/null || true
    fi

    log "Sende neuesten Snapshot: $LATEST_SNAP -> $DST"

    # Transfer mit Raw (-w) und Error-Log
    if ! zfs send -R -w "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
         handle_error "Fehler beim Transfer (Details im Log): $LATEST_SNAP -> $DST" $LINENO
    fi
done

###############################################################################
# 6. Pool exportieren
###############################################################################
log "Exportiere Pool '$POOL_NAME'..."
zpool export "$POOL_NAME" || handle_error "Konnte Pool nicht exportieren." $LINENO

###############################################################################
# 7. VMs starten
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
# 8. Abschluss
###############################################################################
log "##### Backup erfolgreich abgeschlossen #####"
set_status 0 "Backup erfolgreich"
create_checkmk_spool 0 "Backup erfolgreich abgeschlossen."

trap - ERR # Trap entfernen
exit 0
