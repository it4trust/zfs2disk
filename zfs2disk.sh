#!/bin/bash
# zfs2disk.sh – Backup-Skript für Proxmox mit ZFS
# Version 3.0 - Incremental & Import Mode
#
# Aufruf: ./zfs2disk.sh <config_file>
#
# NEU IN V3.0:
# - Versucht, den Backup-Pool zu importieren, statt ihn zu löschen.
# - Führt inkrementelle Backups durch ("nur Änderungen senden").
# - Fallback auf Full-Backup, wenn Destination leer ist.

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
    # $1 = Status (0=OK, 1=WARN, 2=CRIT)
    # $2 = Text Message
    mkdir -p "$CHECKMK_SPOOL_DIR"
    
    # Wir fügen Metadaten für CheckMK hinzu
    # Damit CheckMK das Alter prüfen kann, muss die Datei neu geschrieben werden.
    # Der Text enthält nun das Ablaufdatum als Info.
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

    # Versuch, den Pool sauber zu exportieren, falls gemountet
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
log "##### Backup-Prozess gestartet (Wipe: $FORCE_FULL_WIPE, Inc-Mode) #####"
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
# 2. Pool Management (Import oder Create)
###############################################################################
POOL_IMPORTED=0

# Falls FORCE_FULL_WIPE gewünscht ist, zerstören wir den Pool hart
if [[ "$FORCE_FULL_WIPE" == "yes" ]]; then
    if zpool list "$POOL_NAME" &>/dev/null; then
        log "FORCE WIPE: Zerstöre existierenden Pool '$POOL_NAME'..."
        zpool destroy "$POOL_NAME" || handle_error "Konnte Pool nicht zerstören." $LINENO
    fi
    # Versuchen, auch exportierte Pools zu löschen (labelclear)
    # Vorsichtshalber nur, wenn wir sicher sind
fi

# Prüfen, ob Pool schon gemountet ist
if zpool list "$POOL_NAME" &>/dev/null; then
    log "Pool '$POOL_NAME' ist bereits importiert."
    POOL_IMPORTED=1
else
    # Versuchen zu importieren (Suche auf der externen Disk)
    log "Versuche Pool '$POOL_NAME' zu importieren..."
    # -d sucht in spezifischem Verzeichnis, -f erzwingt Import auch wenn er auf anderem System war
    if zpool import -d /dev/disk/by-id/ -f "$POOL_NAME" 2>/dev/null; then
        log "Import erfolgreich."
        POOL_IMPORTED=1
    else
        log "Konnte Pool nicht importieren (vielleicht existiert er noch nicht?)."
    fi
fi

# Wenn nicht importiert, dann neu erstellen (Initial Backup)
if [[ "$POOL_IMPORTED" -eq 0 ]]; then
    log "Erstelle NEUEN Pool '$POOL_NAME' auf $EXTERNAL_DEVICE..."
    zpool create -f -o ashift=12 "$POOL_NAME" /dev/disk/by-id/"$EXTERNAL_DEVICE" \
        || handle_error "Pool konnte nicht erstellt werden." $LINENO
    zfs set com.sun:auto-snapshot=false "$POOL_NAME" || true
    log "Neuer Pool erstellt. Führe Full-Backup durch."
fi

###############################################################################
# 3. VMs herunterfahren
###############################################################################
# (Hier unverändert, wird ausgeführt wenn VMs definiert sind)
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

    # Rekursive Liste aller Datasets
    ALL_DATASETS=$(zfs list -H -r -o name "$SRC_ROOT")

    for CURRENT_DS in $ALL_DATASETS; do
        if is_excluded "$CURRENT_DS"; then
            log "Überspringe Exclude: $CURRENT_DS"
            continue
        fi

        # Quell-Snapshots holen
        SNAPS_LIST=$(zfs list -H -t snapshot -o name -S creation -d 1 "$CURRENT_DS" 2>/dev/null)
        
        if [[ -z "$SNAPS_LIST" ]]; then
            continue # Nichts zu tun
        fi

        LATEST_SNAP=$(echo "$SNAPS_LIST" | head -n 1) # Neuster auf Quelle
        OLDEST_SNAP=$(echo "$SNAPS_LIST" | tail -n 1) # Ältester auf Quelle

        # Ziel-Pfad berechnen
        REL_PATH="${CURRENT_DS#*/}"
        DST="$POOL_NAME/$REL_PATH"

        # Prüfen: Existiert das Dataset auf dem Ziel (Backup-Platte)?
        DEST_EXISTS=0
        if zfs list "$DST" >/dev/null 2>&1; then
            DEST_EXISTS=1
        else
            # Parent erstellen, falls nötig
            PARENT_DST="${DST%/*}"
            if [[ "$PARENT_DST" != "$POOL_NAME" ]]; then
                zfs create -p "$PARENT_DST" 2>/dev/null || true
            fi
        fi

        # --- LOGIK ENTSCHEIDUNG ---
        
        if [[ "$DEST_EXISTS" -eq 0 ]]; then
            # === FALL A: Initiales Backup (Dataset fehlt auf Ziel) ===
            log "[FULL] Dataset $DST fehlt auf Ziel. Sende komplett..."
            
            if [[ "$BACKUP_MODE" == "latest" && "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                 # Nur den neusten senden
                 zfs send -w -p "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
            else
                 # Historie senden (Basis + Increment)
                 # 1. Basis
                 zfs send -w -p "$OLDEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                 # 2. Update bis LATEST (falls unterschiedlich)
                 if [[ "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                    zfs send -w -p -I "$OLDEST_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                 fi
            fi

        else
            # === FALL B: Inkrementelles Update (Dataset existiert auf Ziel) ===
            
            # Wir suchen den neuesten Snapshot AUF DEM ZIEL
            LATEST_DEST_SNAP_FULL=$(zfs list -H -t snapshot -o name -S creation -d 1 "$DST" 2>/dev/null | head -n 1)
            
            if [[ -z "$LATEST_DEST_SNAP_FULL" ]]; then
                log "[WARN] Ziel $DST existiert, hat aber keine Snapshots. Mache Full Overwrite."
                # Fallback wie Fall A
                zfs send -w -p "$OLDEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                if [[ "$LATEST_SNAP" != "$OLDEST_SNAP" ]]; then
                    zfs send -w -p -I "$OLDEST_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"
                fi
                continue
            fi

            # Den Snapshot-Namen extrahieren (alles nach dem @)
            COMMON_SNAP_NAME="${LATEST_DEST_SNAP_FULL#*@}"
            
            # Prüfen, ob dieser Snapshot auf der QUELLE existiert
            COMMON_SNAP_SRC="${CURRENT_DS}@${COMMON_SNAP_NAME}"
            
            if zfs list -t snapshot "$COMMON_SNAP_SRC" >/dev/null 2>&1; then
                # JA! Wir haben eine gemeinsame Basis.
                
                if [[ "$COMMON_SNAP_SRC" == "$LATEST_SNAP" ]]; then
                    log "[OK]   Ziel $DST ist bereits aktuell ($COMMON_SNAP_NAME)."
                else
                    log "[INC]  Inkrementelles Update für $DST: @$COMMON_SNAP_NAME -> @${LATEST_SNAP#*@}"
                    
                    # Inkrementell senden (-I vom Common zum Latest)
                    if ! zfs send -w -p -I "$COMMON_SNAP_SRC" "$LATEST_SNAP" 2>>"$LOGFILE" | zfs receive -F -u "$DST" 2>>"$LOGFILE"; then
                         log "[ERR]  Fehler beim inkrementellen Update von $CURRENT_DS. Siehe Log."
                         # Optional: Rollback on fail?
                    fi
                fi
            else
                log "[WARN] Split-Brain bei $DST! Ziel hat Snapshot @$COMMON_SNAP_NAME, Quelle aber nicht mehr."
                log "       Muss Rollback am Ziel erzwingen oder komplett neu senden. (Aktuell: Überspringe Sicherung, um Daten nicht zu löschen)"
                # Hier könnte man entscheiden: zfs destroy dest und neu senden? 
                # Aus Sicherheitsgründen lassen wir das hier erst mal manuell lösen.
            fi
        fi
    done
done

###############################################################################
# 5. VMs starten (unverändert)
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
create_checkmk_spool 0 "Backup erfolgreich. (Gültig für ${CHECKMK_EXPIRY_DAYS} Tage)"

trap - ERR 
exit 0
