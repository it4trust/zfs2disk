#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS

LOGFILE="/var/log/zfs2disk.log"
STATUSFILE="/var/log/zfs2disk_status"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -euo pipefail

###############################################################################
# Konfiguration laden
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/zfs2disk.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Konfiguration geladen: $CONFIG_FILE"
else
    echo "Konfigurationsdatei $CONFIG_FILE nicht gefunden." >&2
    exit 1
fi

###############################################################################
# CheckMK
###############################################################################
CHECKMK_SPOOL_DIR="/var/lib/check_mk_agent/spool"
HOSTNAME=$(hostname -f)
SERVICE_NAME="zfs2disk"
SPOOL_FILE="${CHECKMK_SPOOL_DIR}/90000_${HOSTNAME}:${SERVICE_NAME}"

###############################################################################
# Logging & Status
###############################################################################
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
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
    log "FEHLER: $1"
    set_status 2 "$1"
    create_checkmk_spool 2 "$1"
    exit 1
}

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
# 1. Externe Platte finden — **korrekter Fix**
###############################################################################
EXTERNAL_DEVICE=""

for serial in "${EXTERNAL_SERIALS[@]}"; do
    # finde präzise *nur* das Device ohne Partitionen
    dev=$(ls /dev/disk/by-id/ | grep -E "^${serial}$" | head -n1 || true)

    if [[ -n "$dev" ]]; then
        EXTERNAL_DEVICE="$dev"
        log "Gefunden: /dev/disk/by-id/$dev"
        break
    fi
done

[[ -z "$EXTERNAL_DEVICE" ]] && handle_error "Keine externe Platte gefunden."

###############################################################################
# 2. alten Pool entfernen
###############################################################################
if zpool list "$POOL_NAME" &>/dev/null; then
    log "Entferne alten Pool '$POOL_NAME'..."
    zpool destroy "$POOL_NAME" || handle_error "Pool konnte nicht zerstört werden."
else
    log "Kein alter Pool vorhanden."
fi

###############################################################################
# 3. neuen Pool anlegen
###############################################################################
log "Erstelle neuen Pool '$POOL_NAME'..."
zpool create -f -o ashift=12 "$POOL_NAME" /dev/disk/by-id/"$EXTERNAL_DEVICE" \
    || handle_error "Pool konnte nicht erstellt werden."

# Datasets im Ziel-Pool anlegen
for target in "${TARGET_NAMES[@]}"; do
    zfs create "$POOL_NAME/$target" \
        || handle_error "Dataset '$POOL_NAME/$target' konnte nicht erstellt werden."
done

# Autosnapshot-Funktion deaktivieren
zfs set com.sun:auto-snapshot=false "$POOL_NAME" || true

###############################################################################
# 4. VMs herunterfahren
###############################################################################
log "Fahre Maschinen herunter: ${VM_IDS[*]}"

for vm in "${VM_IDS[@]}"; do
    if qm status "$vm" &>/dev/null; then
        state=$(qm status "$vm" | awk '{print $2}')
        [[ "$state" != "stopped" ]] && qm shutdown "$vm"
    elif pct status "$vm" &>/dev/null; then
        state=$(pct status "$vm" | awk -F": " '{print $2}')
        [[ "$state" != "stopped" ]] && pct shutdown "$vm"
    else
        handle_error "Maschine $vm nicht gefunden."
    fi
done

sleep "$WAIT_AFTER_CRITICAL"

###############################################################################
# 5. alte Backup-Snapshots entfernen
###############################################################################
log "Entferne alte Backup-Snapshots..."

for DS in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$DS"; then
        log "Überspringe Ausschluss-Dataset: $DS"
        continue
    fi

    snaps=$(zfs list -H -o name -t snapshot "$DS" | grep "^${DS}@backup-" || true)

    for snap in $snaps; do
        [[ "$snap" != "${DS}@${SNAP_SUFFIX}" ]] && zfs destroy -r "$snap" || true
    done
done

###############################################################################
# 6. neue Snapshots erstellen
###############################################################################
log "Erstelle neue Snapshots..."

for DS in "${SOURCE_DATASETS[@]}"; do
    if is_excluded "$DS"; then
        log "Kein Snapshot für ausgeschlossenes Dataset: $DS"
        continue
    fi

    zfs snapshot -r "${DS}@${SNAP_SUFFIX}" \
        || handle_error "Snapshot fehlgeschlagen: $DS"
done

###############################################################################
# 7. Snapshots senden
###############################################################################
log "Übertrage Snapshots auf $POOL_NAME..."

for i in "${!SOURCE_DATASETS[@]}"; do
    SRC="${SOURCE_DATASETS[$i]}"
    DST="$POOL_NAME/${TARGET_NAMES[$i]}"
    SNAP="${SRC}@${SNAP_SUFFIX}"

    if is_excluded "$SRC"; then
        log "Überspringe Transfer (exclude): $SRC"
        continue
    fi

    log "Sende $SNAP → $DST"
    zfs send -R "$SNAP" | zfs receive -F "$DST" \
        || handle_error "Fehler beim Transfer: $SRC"
done

###############################################################################
# 8. Pool exportieren
###############################################################################
log "Exportiere Pool '$POOL_NAME'..."
zpool export "$POOL_NAME" || handle_error "Konnte Pool nicht exportieren."

###############################################################################
# 9. VMs starten
###############################################################################
log "Starte Maschinen neu..."

for vm in "${VM_IDS[@]}"; do
    if qm status "$vm" &>/dev/null; then
        qm start "$vm" || handle_error "Start fehlgeschlagen: VM $vm"
    elif pct status "$vm" &>/dev/null; then
        pct start "$vm" || handle_error "Start fehlgeschlagen: LXC $vm"
    fi
done

###############################################################################
# 10. Abschluss
###############################################################################
log "##### Backup erfolgreich abgeschlossen #####"
set_status 0 "Backup erfolgreich"
create_checkmk_spool 0 "Backup erfolgreich abgeschlossen."

exit 0
