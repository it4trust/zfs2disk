#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS
# Version 2.0 - Hybrid Mode (Latest vs. Full History)
#
# Aufruf: ./zfs2disk.sh <config_file>
#
# NEU IN V2.0:
# - Unterstützung für BACKUP_MODE="latest" (nur neuester Snap) oder "full" (komplette Historie).
# - Wird in der .conf Datei definiert. Default ist "full".

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

# Default für BACKUP_MODE setzen, falls nicht in Config definiert
BACKUP_MODE="${BACKUP_MODE:-full}"

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
    if [ -z "${EXCLUDE_DATASETS+x}" ]; then return 1; fi
    for ex in "${EXCLUDE_DATASETS[@]}"; do
        if [[ "$ds" == "$ex" ]]; then return 0; fi
    done
    return 1
}

###############################################################################
# Backup beginnt
###############################################################################
log "##### Backup-Prozess gestartet (Mode: $BACKUP_MODE) #####"
create_checkmk_spool 1 "Backup läuft (Mode: $BACKUP_MODE)..."

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
# 5. Snapshots senden (Hybrid Logic)
###############################################################################
log "Analysiere Datasets und übertrage..."

for SRC_ROOT in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$SRC_ROOT"; then continue; fi

    if ! zfs list -H -o name "$SRC_ROOT" >/dev/null 2>&1; then
        log "WARNUNG: Dataset '$SRC_ROOT' existiert nicht. Überspringe."
        continue
    fi

    # Rekursive Liste aller Datasets holen
    ALL_DATASETS=$(zfs list -H -r -o name "$SRC_ROOT")

    for CURRENT_DS in $ALL_DATASETS; do
        if is_excluded "$CURRENT_DS"; then
            log "Überspringe Exclude: $CURRENT_DS"
            continue
        fi

        # 1. Alle Snapshots holen (sortiert nach Erstellung: Alt -> Neu)
        # Wir brauchen die Liste in beiden Fällen, um den neuesten zu finden
        SNAPS_LIST=$(zfs list -H -t snapshot -o name -S creation -d 1 "$CURRENT_DS" 2>/dev/null)
        
        if [[ -z "$SNAPS_LIST" ]]; then
            # Keine Snapshots -> Nichts zu tun
            continue
        fi

        # Neuesten Snapshot ermitteln (head -n 1 weil -S creation sortiert)
        LATEST_SNAP=$(echo "$SNAPS_LIST" | head -n 1)

        # Ziel-Pfad vorbereiten
        REL_PATH="${CURRENT_DS#*/}"
        DST="$POOL_NAME/$REL_PATH"
        PARENT_DST="${DST%/*}"

        if [[ "$PARENT_DST" != "$POOL_NAME" ]]; then
            zfs create -p "$PARENT_DST" 2>/dev/null || true
        fi

        # --- ENTSCHEIDUNG: LATEST ONLY vs. FULL HISTORY ---
        
        if [[ "$BACKUP_MODE" == "latest" ]]; then
            # === MODE: LATEST ONLY ===
            # Wir senden nur den allerletzten Snapshot. Historie wird ignoriert.
            log "Sende Latest ($LATEST_SNAP) -> $DST"
            
            if ! zfs send -w -p "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                 log "WARNUNG: Fehler beim Transfer (Latest) von $CURRENT_DS."
            fi

        else
            # === MODE: FULL HISTORY (Default) ===
            OLDEST_SNAP=$(echo "$SNAPS_LIST" | tail -n 1)

            if [[ "$LATEST_SNAP" == "$OLDEST_SNAP" ]]; then
                # Sonderfall: Nur ein Snapshot da, egal ob Full oder Latest
                log "Sende Single-Snapshot ($LATEST_SNAP) -> $DST"
                if ! zfs send -w -p "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                     log "WARNUNG: Fehler beim Single-Transfer von $CURRENT_DS."
                fi
            else
                # Echte Historie senden
                log "Sende Basis ($OLDEST_SNAP) bis ($LATEST_SNAP) -> $DST"
                
                # Schritt 1: Basis
                if ! zfs send -w -p "$OLDEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                     log "WARNUNG: Fehler beim Basis-Transfer von $CURRENT_DS."
                     continue
                fi

                # Schritt 2: Inkrementell
                if ! zfs send -w -p -I "$OLDEST_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                     log "WARNUNG: Fehler beim History-Update von $CURRENT_DS."
                fi
            fi
        fi
    done
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
