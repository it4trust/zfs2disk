#!/bin/bash
# zfs2disk.sh - Backup-Skript für Proxmox mit ZFS (externen Pool-Wechsel)
# 
# Installation:
# 1. Erstelle Verzeichnis: mkdir -p /root/zfs2disk
# 2. Kopiere dieses Skript nach: /root/zfs2disk/zfs2disk.sh
# 3. Kopiere die Konfigurationsdatei nach: /root/zfs2disk/zfs2disk.conf
# 4. Setze Ausführungsrechte: chmod +x /root/zfs2disk/zfs2disk.sh
# 5. Crontab Eintrag: 0 21 * * * /root/zfs2disk/zfs2disk.sh
#
# Dieses Skript wird via Cronjob täglich um 21 Uhr ausgeführt.
#
# WICHTIG: rpool wird NICHT gelöscht oder verändert.
# Es werden lediglich Snapshots von rpool-Datasets erstellt und
# die Daten auf den Pool "backuppool" übertragen.
#
# Neuer Ablauf:
#   1. Externe Platte prüfen und ggf. alten backuppool löschen.
#   2. Neuen backuppool (mit ashift=12) und dessen Datasets anlegen.
#   3. Globale Deaktivierung der Autosnapshot-Funktion für den Pool "backuppool".
#   4. Herunterfahren der Maschinen (VMs/LXC); falls diese bereits heruntergefahren sind, wird nur geloggt.
#   5. Warten (WAIT_AFTER_CRITICAL).
#   6. Lösche vorhandene Backup-Snapshots in den Quell-Datasets, die NICHT
#      dem aktuellen SNAP_SUFFIX entsprechen.
#   7. Erstelle neue rekursive Snapshots der Quell-Datasets (mit dem Präfix "backup-").
#   8. Übertrage die neuen Snapshots von rpool nach backuppool.
#   9. (Löschen der Quell-Snapshots erfolgt beim nächsten Skriptlauf.)
#  10. Exportiere den Pool backuppool.
#  11. Starte die Maschinen neu.
#  12. Erstelle CheckMK Spool-Datei für persistenten Status.
#
# zfs2disk.conf - Konfigurationsdatei für das ZFS Backup Skript
# Diese Datei muss im gleichen Verzeichnis wie zfs2disk.sh liegen
# Logdatei (empfohlen wird die externe Logrotation per logrotate)
LOGFILE="/var/log/zfs2disk.log"
# Statusdatei für Checkmk-Plugin (enthält letzte Erfolgsmeldung und Fehler)
STATUSFILE="/var/log/zfs2disk_status"

# Setze PATH, damit auch in der Cron-Umgebung alle Befehle gefunden werden
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

set -euo pipefail

###############################################################################
# Konfiguration laden
###############################################################################
# Ermittle das Verzeichnis, in dem das Skript liegt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/zfs2disk.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Konfiguration geladen aus: $CONFIG_FILE"
else
    echo "Konfigurationsdatei $CONFIG_FILE nicht gefunden. Abbruch."
    echo "Erwartet wird die Datei im gleichen Verzeichnis wie das Skript: $SCRIPT_DIR"
    exit 1
fi

###############################################################################
# CheckMK Spool-Konfiguration
###############################################################################
# CheckMK Spool-Verzeichnis
CHECKMK_SPOOL_DIR="/var/lib/check_mk_agent/spool"
# Hostname für CheckMK (automatisch ermittelt)
HOSTNAME=$(hostname -f)
# Service-Name für CheckMK
SERVICE_NAME="zfs2disk"
# Spool-Dateiname (90000 = 25 Stunden Gültigkeit)
SPOOL_FILE="${CHECKMK_SPOOL_DIR}/90000_${HOSTNAME}:${SERVICE_NAME}"

###############################################################################
# Log- und Statusfunktionen
###############################################################################
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

set_status() {
    local code="$1"
    local message="$2"
    echo "LastStatus: $code" > "$STATUSFILE"
    echo "LastMessage: $message" >> "$STATUSFILE"
}

# Neue Funktion für CheckMK Spool-Datei
create_checkmk_spool() {
    local status="$1"
    local message="$2"
    local timestamp=$(date +%s)
    
    # Erstelle Spool-Verzeichnis falls es nicht existiert
    mkdir -p "$CHECKMK_SPOOL_DIR"
    
    # Erstelle CheckMK Spool-Datei mit korrektem Format
    cat > "$SPOOL_FILE" << EOF
<<<local>>>
$status $SERVICE_NAME - $message ($(date +'%Y-%m-%d %H:%M:%S'))
EOF
    
    log "CheckMK Spool-Datei erstellt: $SPOOL_FILE mit Status $status"
}

###############################################################################
# Fehlerbehandlung mit CheckMK Integration
###############################################################################
handle_error() {
    local error_msg="$1"
    log "FEHLER: $error_msg"
    set_status 2 "$error_msg"
    create_checkmk_spool 2 "$error_msg"
    exit 1
}

###############################################################################
# Start des Backup-Prozesses
###############################################################################
log "#################### Backup-Prozess gestartet ####################"
ERROR_OCCURRED=0

# Erstelle initiale CheckMK Spool-Datei (Backup läuft)
create_checkmk_spool 1 "zfs2disk wird ausgeführt..."

###############################################################################
# 1. Prüfe, ob eine externe Platte mit einer der definierten Seriennummern angeschlossen ist
###############################################################################
EXTERNAL_DEVICE=""
for serial in "${EXTERNAL_SERIALS[@]}"; do
    device=$(ls /dev/disk/by-id/ 2>/dev/null | grep "$serial" | head -n 1 || true)
    if [ -n "$device" ]; then
        EXTERNAL_DEVICE="$device"
        log "Gefundene externe Platte mit Seriennummer $serial: /dev/disk/by-id/$device"
        break
    fi
done
if [ -z "$EXTERNAL_DEVICE" ]; then
    handle_error "Keine externe Platte mit den angegebenen Seriennummern gefunden."
fi

###############################################################################
# 2. Importiere und zerstöre alten backuppool (nur dieser Pool wird manipuliert, rpool bleibt unberührt)
###############################################################################
if zpool list "$POOL_NAME" &>/dev/null; then
    log "Zerstöre existierenden Pool '$POOL_NAME'..."
    if zpool destroy "$POOL_NAME"; then
        log "Pool '$POOL_NAME' wurde erfolgreich zerstört."
    else
        handle_error "Fehler beim Zerstören von Pool '$POOL_NAME'."
    fi
else
    log "Pool '$POOL_NAME' existiert nicht. Kein Destroy notwendig."
fi

###############################################################################
# 3. Erstelle neuen backuppool mit ashift=12 und lege die benötigten Datasets an
###############################################################################
log "Erstelle neuen ZFS Pool '$POOL_NAME' auf der externen Platte mit ashift=12..."
if zpool create -f -o ashift=12 "$POOL_NAME" /dev/disk/by-id/"$EXTERNAL_DEVICE"; then
    log "Pool '$POOL_NAME' wurde erstellt."
else
    handle_error "Konnte Pool '$POOL_NAME' nicht erstellen."
fi

log "Erstelle Datasets im Pool '$POOL_NAME'..."
for target in "${TARGET_NAMES[@]}"; do
    if zfs create "$POOL_NAME/$target"; then
        log "Dataset '$POOL_NAME/$target' erstellt."
    else
        handle_error "Konnte Dataset '$POOL_NAME/$target' nicht erstellen."
    fi
done

# 3b. Deaktiviere global die Autosnapshot-Funktion ausschließlich für den Pool "backuppool"
log "Setze globale Eigenschaft: Deaktiviere Autosnapshot für $POOL_NAME..."
if zfs set com.sun:auto-snapshot=false "$POOL_NAME"; then
    log "Autosnapshot-Funktion für $POOL_NAME und alle untergeordneten Datasets deaktiviert."
else
    log "Warnung: Konnte die Autosnapshot-Funktion für $POOL_NAME nicht deaktivieren."
fi

###############################################################################
# 4. Fahre die in VM_IDS angegebenen Maschinen herunter (Maschinen bereits herunter? -> Logge, aber mache weiter)
###############################################################################
log "Fahre Maschinen herunter: ${VM_IDS[*]} ..."
for vm in "${VM_IDS[@]}"; do
    machine_type=""
    if /usr/sbin/qm status "$vm" &>/dev/null; then
        machine_type="qm"
    elif /usr/sbin/pct status "$vm" &>/dev/null; then
        machine_type="pct"
    else
        handle_error "Maschine mit ID $vm wurde nicht gefunden."
    fi

    # Prüfe, ob Maschine bereits gestoppt ist
    if [ "$machine_type" = "qm" ]; then
        state=$(/usr/sbin/qm status "$vm" | awk '{print $2}')
    else
        state=$(/usr/sbin/pct status "$vm" | awk -F": " '/status/ {print $2}')
    fi
    if [ "$state" == "stopped" ]; then
        log "Maschine $vm (Typ: $machine_type) ist bereits heruntergefahren."
    else
        log "Fahre Maschine $vm (Typ: $machine_type) herunter..."
        if [ "$machine_type" = "qm" ]; then
            if /usr/sbin/qm shutdown "$vm"; then
                log "Shutdown-Befehl für VM $vm gesendet."
            else
                handle_error "Konnte VM $vm nicht herunterfahren."
            fi
        elif [ "$machine_type" = "pct" ]; then
            if /usr/sbin/pct shutdown "$vm"; then
                log "Shutdown-Befehl für LXC $vm gesendet."
            else
                handle_error "Konnte LXC $vm nicht herunterfahren."
            fi
        fi
    fi
done

# Überprüfe den Status aller Maschinen (alle 10 Sekunden, bis zu VM_CHECK_RETRIES)
for vm in "${VM_IDS[@]}"; do
    if /usr/sbin/qm status "$vm" &>/dev/null; then
        machine_type="qm"
    elif /usr/sbin/pct status "$vm" &>/dev/null; then
        machine_type="pct"
    fi
    for ((i=1; i<=VM_CHECK_RETRIES; i++)); do
        sleep 10
        if [ "$machine_type" = "qm" ]; then
            state=$(/usr/sbin/qm status "$vm" | awk '{print $2}')
        elif [ "$machine_type" = "pct" ]; then
            state=$(/usr/sbin/pct status "$vm" | awk -F": " '/status/ {print $2}')
        fi
        if [ "$state" == "stopped" ]; then
            log "Maschine $vm (Typ: $machine_type) ist heruntergefahren."
            break
        fi
        if [ "$i" -eq "$VM_CHECK_RETRIES" ]; then
            handle_error "Maschine $vm (Typ: $machine_type) ist nach mehrfacher Prüfung nicht gestoppt."
        fi
    done
done
log "Warte weitere $WAIT_AFTER_CRITICAL Sekunden..."
sleep "$WAIT_AFTER_CRITICAL"

###############################################################################
# 5. Lösche vorhandene Backup-Snapshots in den Quell-Datasets,
#    die NICHT dem aktuellen SNAP_SUFFIX entsprechen
###############################################################################
log "Prüfe und lösche vorhandene Backup-Snapshots in den Quell-Datasets..."
for DS in "${SOURCE_DATASETS[@]}"; do
    existing_snaps=$(zfs list -H -o name -t snapshot "$DS" | awk -F@ '{print $2}' | grep '^backup-' || true)
    if [ -n "$existing_snaps" ]; then
        for snap in $existing_snaps; do
            if [ "$snap" != "${SNAP_SUFFIX}" ]; then
                full_snap="${DS}@${snap}"
                log "Lösche vorhandenen Backup-Snapshot $full_snap..."
                zfs destroy -r "$full_snap" || log "Warnung: Konnte $full_snap nicht löschen."
            else
                log "Behalte aktuellen Backup-Snapshot ${DS}@${snap} (aktueller Lauf)."
            fi
        done
    fi
done

###############################################################################
# 6. Erstelle neue rekursive Snapshots der Quell-Datasets (mit dem Präfix "backup-")
###############################################################################
log "Erstelle neue rekursive Snapshots der Quell-Datasets..."
for DS in "${SOURCE_DATASETS[@]}"; do
    SNAP="${DS}@${SNAP_SUFFIX}"
    if zfs snapshot -r "$SNAP"; then
        log "Neuer rekursiver Snapshot erstellt: $SNAP"
    else
        handle_error "Neuer rekursiver Snapshot konnte nicht erstellt werden für $DS"
    fi
done

###############################################################################
# 7. Übertrage die neuen Snapshots von rpool (Quell-Datasets) in den neuen backuppool
###############################################################################
log "Starte die Übertragung der Datasets per zfs send/receive..."
for index in "${!SOURCE_DATASETS[@]}"; do
    SRC_DS="${SOURCE_DATASETS[$index]}"
    SNAP="${SRC_DS}@${SNAP_SUFFIX}"
    TARGET_DS="$POOL_NAME/${TARGET_NAMES[$index]}"

    log "Übertrage $SNAP nach $TARGET_DS..."
    if zfs send -R "$SNAP" | zfs receive -F "$TARGET_DS"; then
        log "Daten von $SNAP erfolgreich übertragen nach $TARGET_DS."

        log "Deaktiviere Autosnapshot-Funktion für $TARGET_DS..."
        if zfs inherit com.sun:auto-snapshot "$TARGET_DS"; then
            log "Geerbte Autosnapshot-Funktion für $TARGET_DS zurückgesetzt."
        fi
        if zfs set com.sun:auto-snapshot=false "$TARGET_DS"; then
            log "Autosnapshot-Funktion für $TARGET_DS deaktiviert."
        else
            log "Warnung: Konnte Autosnapshot-Funktion für $TARGET_DS nicht deaktivieren."
        fi

        log "Behalte aktuellen lokalen Snapshot $SNAP für diesen Lauf."
    else
        handle_error "Übertragung von $SNAP nach $TARGET_DS fehlgeschlagen."
    fi
done

###############################################################################
# 8. Exportiere den Pool "$POOL_NAME", damit die Platte sicher ausgetauscht werden kann
###############################################################################
log "Exportiere den Pool '$POOL_NAME'..."
if zpool export "$POOL_NAME"; then
    log "Pool '$POOL_NAME' wurde erfolgreich exportiert."
else
    handle_error "Konnte Pool '$POOL_NAME' nicht exportieren."
fi

###############################################################################
# 9. Starte die in VM_IDS angegebenen Maschinen neu (QEMU und LXC)
###############################################################################
log "Starte Maschinen neu: ${VM_IDS[*]} ..."
for vm in "${VM_IDS[@]}"; do
    machine_type=""
    if /usr/sbin/qm status "$vm" &>/dev/null; then
        machine_type="qm"
    elif /usr/sbin/pct status "$vm" &>/dev/null; then
        machine_type="pct"
    fi

    log "Starte Maschine $vm (Typ: $machine_type)..."
    if [ "$machine_type" = "qm" ]; then
        if /usr/sbin/qm start "$vm"; then
            log "VM $vm wurde erfolgreich gestartet."
        else
            handle_error "Konnte VM $vm nicht starten."
        fi
    elif [ "$machine_type" = "pct" ]; then
        if /usr/sbin/pct start "$vm"; then
            log "LXC $vm wurde erfolgreich gestartet."
        else
            handle_error "Konnte LXC $vm nicht starten."
        fi
    fi
done

###############################################################################
# 10. Erstelle finale CheckMK Spool-Datei (Erfolg)
###############################################################################
log "#################### Backup-Prozess abgeschlossen ####################"
set_status 0 "Backup erfolgreich abgeschlossen am $(date +'%Y-%m-%d %H:%M:%S')"

# Erstelle finale CheckMK Spool-Datei mit Erfolgsmeldung
create_checkmk_spool 0 "zfs2disk erfolgreich abgeschlossen am $(date +'%Y-%m-%d %H:%M:%S'). Pool $POOL_NAME exportiert."

log "CheckMK wird den Status für 25 Stunden als OK anzeigen, auch wenn der Pool exportiert ist."

exit 0
