# zfs2disk

Ein robustes Backup-Skript für Proxmox VE mit ZFS, das automatisch Snapshots auf externe Festplatten sichert und CheckMK-Integration bietet.

## 🚀 Features

- **Automatische ZFS-Snapshots** von konfigurierbaren Datasets
- **Externe Festplatten-Unterstützung** mit Pool-Export für sicheren Transport
- **VM/LXC Management** - Automatisches Herunterfahren und Starten
- **CheckMK-Integration** mit 25h Status-Persistenz
- **Intelligente Fehlerbehandlung** mit detailliertem Logging
- **Flexible Konfiguration** über separate Config-Datei

## 📋 Voraussetzungen

- Proxmox VE mit ZFS
- Root-Zugriff
- Externe USB/SATA-Festplatte(n)
- CheckMK-Agent (optional, für Monitoring)

## 🛠️ Installation

### 1. Repository klonen
```bash
git clone https://github.com/[IhrUsername]/zfs2disk.git
cd zfs2disk
```

### 2. Dateien kopieren
```bash
# Verzeichnis erstellen
mkdir -p /root/zfs2disk

# Skript und Konfiguration kopieren
cp zfs2disk.sh /root/zfs2disk/
cp zfs2disk.conf /root/zfs2disk/

# Ausführungsrechte setzen
chmod +x /root/zfs2disk/zfs2disk.sh
```

### 3. Konfiguration anpassen
```bash
nano /root/zfs2disk/zfs2disk.conf
```

**Wichtige Einstellungen:**
- `EXTERNAL_SERIALS`: Seriennummern Ihrer externen Festplatten
- `SOURCE_DATASETS`: Zu sichernde ZFS-Datasets
- `VM_IDS`: IDs der VMs/LXCs die gestoppt werden sollen

### 4. Seriennummern der externen Festplatten ermitteln
```bash
ls -la /dev/disk/by-id/ | grep usb
```

### 5. Cronjob einrichten
```bash
crontab -e
# Täglich um 21:00 Uhr ausführen:
0 21 * * * /root/zfs2disk/zfs2disk.sh
```

## ⚙️ Konfiguration

### Beispiel-Konfiguration (zfs2disk.conf)
```bash
# Externe Festplatten (Seriennummern anpassen!)
EXTERNAL_SERIALS=("usb-TOSHIBA_EXTERNAL_USB_20231121000271F-0:0")

# Quell-Datasets auf rpool
SOURCE_DATASETS=("rpool/pveconf" "rpool/data" "rpool/ROOT")

# Ziel-Namen im Backup-Pool
TARGET_NAMES=("pveconf" "data" "ROOT")

# VMs/LXCs die gestoppt werden sollen
VM_IDS=(100 101 102)
```

## 🔄 Ablauf

1. **Erkennung** der externen Festplatte anhand Seriennummer
2. **Pool-Erstellung** (`backuppool`) auf externer Platte
3. **VM/LXC-Shutdown** der konfigurierten Maschinen
4. **Snapshot-Erstellung** der Quell-Datasets mit Zeitstempel
5. **Datenübertragung** via `zfs send/receive`
6. **Pool-Export** für sichere Plattentrennung
7. **VM/LXC-Start** aller Maschinen
8. **CheckMK-Status** für 25h persistiert

## 📊 Monitoring

### CheckMK-Integration
Das Skript erstellt automatisch Spool-Dateien für CheckMK:
- **Service-Name:** `zfs2disk`
- **Status-Persistenz:** 25 Stunden
- **Spool-Datei:** `/var/lib/check_mk_agent/spool/90000_[hostname]:zfs2disk`

### Log-Dateien
- **Haupt-Log:** `/var/log/zfs2disk.log`
- **Status-Datei:** `/var/log/zfs2disk_status`

## 🐛 Troubleshooting

### Häufige Probleme

**1. Externe Platte nicht erkannt**
```bash
# Verfügbare Geräte prüfen
ls -la /dev/disk/by-id/ | grep usb
lsblk
```

**2. Pool kann nicht erstellt werden**
```bash
# Bestehenden Pool prüfen/zerstören
zpool status backuppool
zpool destroy backuppool  # Falls vorhanden
```

**3. VM/LXC startet nicht**
```bash
# Status prüfen
qm status 100
pct status 101

# Manuell starten
qm start 100
pct start 101
```

**4. CheckMK zeigt keinen Status**
```bash
# Spool-Verzeichnis prüfen
ls -la /var/lib/check_mk_agent/spool/
cat /var/lib/check_mk_agent/spool/90000_*zfs2disk

# CheckMK-Agent testen
check_mk_agent
```

## 🧪 Test

Vor dem ersten produktiven Einsatz testen:
```bash
# Trockenlauf (Log beobachten)
/root/zfs2disk/zfs2disk.sh
tail -f /var/log/zfs2disk.log
```

## 📝 Logrotation

Empfohlene `/etc/logrotate.d/zfs2disk`:
```
/var/log/zfs2disk.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
}
```

## 🔒 Sicherheitshinweise

- Das Skript läuft als **root** - Konfiguration sorgfältig prüfen
- **Externe Festplatten** sicher verwahren (Verschlüsselung empfohlen)
- **Backup-Strategie** mit mehreren Platten für Rotation
- **Recovery-Test** regelmäßig durchführen

## 🤝 Mitwirken

1. Fork des Repositories erstellen
2. Feature-Branch erstellen (`git checkout -b feature/AmazingFeature`)
3. Änderungen committen (`git commit -m 'Add some AmazingFeature'`)
4. Branch pushen (`git push origin feature/AmazingFeature`)
5. Pull Request erstellen

## 📜 Lizenz

Dieses Projekt steht unter der MIT-Lizenz - siehe [LICENSE](LICENSE) für Details.

## 🙏 Credits

Entwickelt für Proxmox VE Umgebungen mit ZFS-Storage und CheckMK-Monitoring.

---

**⚠️ Wichtiger Hinweis:** Testen Sie das Skript zunächst in einer Testumgebung und stellen Sie sicher, dass Sie funktionierende Backups haben, bevor Sie es produktiv einsetzen!
