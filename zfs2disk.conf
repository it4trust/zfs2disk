#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS
# Version 1.2 - Auto-Target Naming

LOGFILE="/var/log/zfs2disk.log"
STATUSFILE="/var/log/zfs2disk_status"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Error Handling Setup
set -o pipefail  # Return code of pipes is reflected
set -u           # Fail on unset variables

###############################################################################
# Konfiguration laden
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/zfs2disk.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Konfigurationsdatei $CONFIG_FILE nicht gefunden." >&2
    exit 1
fi

###############################################################################
# CheckMK & Logging Basics
###############################################################################
CHECKMK_SPOOL_DIR="/var/lib/check_mk_agent/spool"
HOSTNAME=$(hostname -f)
SERVICE_NAME="zfs2disk"
SPOOL_FILE="${CHECKMK_SPOOL_DIR}/90000_${HOSTNAME}:${SERVICE_NAME}"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

set_status() {
    # $1 = Exit Code (0=OK, 2=CRIT), $2 = Text
    echo "LastStatus: $1"  > "$STATUSFILE"
    echo "LastMessage: $2" >> "$STATUSFILE"
}

create_checkmk_spool() {
    # $1 = Status Code (0=OK, 1=WARN, 2=CRIT), $2 = Text
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
    
    # Versuche Pool zu exportieren, falls er noch gemountet ist (Clean Exit)
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
    for ex in "${EXCLUDE_DATASETS[@]}"; do
        if [[ "$ds" == "$ex" ]]; then
            return 0
        fi
    done
    return 1
}

###############################################################################
# Backup beginnt
###############################################################################
log "##### Backup-Prozess gestartet #####"
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

# Auto-Snapshot auf dem Backup-Medium deaktivieren
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
        else
            log "WARNUNG: Maschine $vm nicht gefunden."
        fi
    done
    
    log "Warte $WAIT_AFTER_CRITICAL Sekunden auf Shutdown..."
    sleep "$WAIT_AFTER_CRITICAL"
else
    log "Keine VMs zum Herunterfahren definiert."
fi

###############################################################################
# 5. alte Backup-Snapshots entfernen
###############################################################################
log "Entferne alte Backup-Snapshots..."

for DS in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$DS"; then
        continue
    fi
    # Nur Snapshots löschen, die mit "backup-" beginnen
    snaps=$(zfs list -H -o name -t snapshot "$DS" | grep "@backup-" || true)

    for snap in $snaps; do
        [[ "$snap" != "${DS}@${SNAP_SUFFIX}" ]] && zfs destroy -r "$snap" || true
    done
done

###############################################################################
# 6. neue Snapshots erstellen
###############################################################################
log "Erstelle neue Snapshots ($SNAP_SUFFIX)..."

for DS in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$DS"; then
        log "Überspringe Snapshot (exclude): $DS"
        continue
    fi

    zfs snapshot -r "${DS}@${SNAP_SUFFIX}" \
        || handle_error "Snapshot fehlgeschlagen: $DS" $LINENO
done

###############################################################################
# 7. Snapshots senden
###############################################################################
log "Übertrage Snapshots auf $POOL_NAME..."

for SRC in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$SRC"; then
        continue
    fi
    
    # Automatische Namensgebung:
    # Aus "rpool/data/vm-100-disk-0" wird "vm-100-disk-0"
    TARGET_NAME=$(basename "$SRC")
    DST="$POOL_NAME/$TARGET_NAME"
    SNAP="${SRC}@${SNAP_SUFFIX}"

    log "Sende $SNAP -> $DST"
    
    # zfs receive erstellt das Dataset im Ziel automatisch
    zfs send -R "$SNAP" | zfs receive -F -u "$DST" \
        || handle_error "Fehler beim Transfer: $SRC -> $DST" $LINENO
done

###############################################################################
# 8. Pool exportieren
###############################################################################
log "Exportiere Pool '$POOL_NAME'..."
zpool export "$POOL_NAME" || handle_error "Konnte Pool nicht exportieren." $LINENO

###############################################################################
# 9. VMs starten
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
# 10. Abschluss
###############################################################################
log "##### Backup erfolgreich abgeschlossen #####"
set_status 0 "Backup erfolgreich"
create_checkmk_spool 0 "Backup erfolgreich abgeschlossen."

trap - ERR # Trap entfernen
exit 0
