# Lab 06 — Automated Backup System

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![WSL2](https://img.shields.io/badge/WSL2-Environment-0078D4?logo=windows&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![tar](https://img.shields.io/badge/tar%20%2B%20gzip-Archives-A00000)
![cron](https://img.shields.io/badge/cron-Daily-6E4C13)
![systemd](https://img.shields.io/badge/systemd-Compatible-333333?logo=systemd&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

> Automated backup system for an Ubuntu server: timestamped `.tar.gz` archives,
> disk space checks, SHA-256 integrity verification, 7-day retention, centralized
> logging, and a daily cron schedule.

---

## Table of Contents

1. [Objective](#1-objective)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Implementation](#4-implementation)
5. [Testing](#5-testing)
6. [Troubleshooting](#6-troubleshooting)
7. [Lessons Learned](#7-lessons-learned)

---

## 1. Objective

Build a **reliable, verifiable, and autonomous** backup system for a Linux server that
protects critical system data without manual intervention.

### Detailed objectives

| # | Objective | Success criterion |
|---|-----------|-------------------|
| 1 | Back up critical directories | Timestamped `.tar.gz` archives of `/etc` and `/var/log` |
| 2 | Guarantee archive integrity | Valid `tar -tzf` listing + verifiable SHA-256 checksum |
| 3 | Avoid filling the disk | Free-space check **before** every run; abort if insufficient |
| 4 | Limit storage growth | Automatic retention: delete archives older than 7 days |
| 5 | Trace every operation | Timestamped log in `/var/log/backup.log` |
| 6 | Automate without forgetting | Daily cron job installed by `--install-cron` |
| 7 | Never publish a partial archive | Write to a `.partial` file, publish atomically after validation |
| 8 | Survive concurrent runs | `flock` lock: only one backup at a time |

### Scope

| Included | Excluded (future work) |
|----------|------------------------|
| Local backup of `/etc` and `/var/log` | Off-site backup (S3, SFTP, remote rsync) |
| Compressed, timestamped archives | Archive encryption (age, GPG) |
| 7-day local retention | Deduplication (restic, borgbackup) |
| Cron scheduling | External monitoring (Prometheus, Healthchecks) |
| Integrity verification | Automated restore tests |

### Deliverables

- `backup.sh` — standalone, idempotent script tested on Ubuntu 24.04 LTS.
- This `README.md` — operations, testing, and troubleshooting documentation.

---

## 2. Architecture

### 2.1 Overview

```
[TIMER]  cron 02:15  /  systemd timer
   │     /etc/cron.d/lab06-backup
   ▼
[backup.sh --quiet]  /usr/local/sbin/backup.sh
   │
   ├─ 1. flock /run/lock/lab06-backup.lock       one run at a time
   ├─ 2. rotate backup.log if > 5 MB             backup.log → backup.log.1
   ├─ 3. df -Pk + du -sk                         free-space check
   ├─ 4. tar -czpf ... .partial                  archive in progress
   ├─ 5. tar -tzf + sha256sum                    integrity check
   ├─ 6. mv .partial → .tar.gz  (chmod 600)      atomic publish
   └─ 7. find -mtime +7 -delete                  retention
   │
   ├──▶ SOURCES       /etc  /var/log  (+ optional directories)
   └──▶ DESTINATION   /var/backups/lab06/
                        backup-YYYYmmdd-HHMMSS.tar.gz
                        backup-YYYYmmdd-HHMMSS.tar.gz.sha256
                        (directory 700 root:root, files 600 root:root)

   LOGGING            /var/log/backup.log  (640 root:root)
                      2026-10-26 02:15:01 [INFO] === backup start (retention 7 day(s)) ===
                      2026-10-26 02:15:02 [OK]   archive integrity verified (tar -tzf)
                      2026-10-26 02:15:02 [OK]   backup completed in 2s
```

### 2.2 Archive lifecycle

```
      creation                 validation                  retention
         │                         │                           │
  .partial.1234 ──tar──▶ .partial.1234 ──tar -tzf──▶ .tar.gz ──find -mtime +7──▶ deleted
         │                         │                           │
         └── failure ──▶ deleted   └── corrupt ──▶ deleted
```

| Stage | File | Guarantee |
|-------|------|-----------|
| Write | `backup-<ts>.tar.gz.partial.<pid>` | Never visible as a valid archive |
| Verify | same file | `tar -tzf` must list contents without error |
| Publish | `backup-<ts>.tar.gz` | Atomic `mv` on the same filesystem |
| Checksum | `backup-<ts>.tar.gz.sha256` | Later verification with `sha256sum -c` |
| Retention | `backup-*.tar.gz` + `.sha256` | Only matching files are deleted |

### 2.3 Naming convention

```
backup-20261026-021500.tar.gz          # archive
backup-20261026-021500.tar.gz.sha256   # associated checksum
backup-20261026-021500-1.tar.gz        # second run within the same second
```

The `YYYYmmdd-HHMMSS` timestamp allows natural chronological sorting and immediate
identification. A `-N` suffix prevents any overwrite if two runs start in the same second.

### 2.4 Retention policy

| Item | Duration | Mechanism |
|------|----------|-----------|
| `.tar.gz` archive | 7 days | `find -mtime +7` |
| `.sha256` checksum | Same as the archive | Deleted together in the same loop |
| `.partial.*` file | 1 day | Cleanup of interrupted runs |
| `backup.log` | 5 MB | Rotation to `backup.log.1` |

> ℹ️ `-mtime +7` means "modified **more than 7 × 24 h** ago". Deletion therefore happens
> no earlier than 7 days after creation — in practice, on the first run past that threshold.

### 2.5 Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success (backup, installation, verification) |
| `1` | Error: insufficient space, fatal tar error, invalid checksum, permissions |
| `2` | Usage error (invalid option) |
| `130` | Interrupted by a signal (`SIGINT` / `SIGTERM`) |

---

## 3. Prerequisites

| Component | Version / Detail | Check |
|-----------|------------------|-------|
| Windows | Windows 10/11 with WSL2 | `wsl -l -v` |
| Distribution | Ubuntu 24.04 LTS | `lsb_release -a` |
| Bash | ≥ 4.4 (arrays, `pipefail`) | `bash --version` |
| Privileges | `root` (read `/etc/shadow`, write `/var/log`) | `sudo -v` |
| Tools | `tar`, `gzip`, `findutils`, `coreutils`, `flock` | `command -v tar gzip find flock` |
| Scheduling | `cron` (package + running service) | `systemctl status cron` |
| systemd (optional) | Timer as an alternative to cron | `systemctl is-system-running` |
| Disk space | ≥ 200 MB free (default threshold) | `df -h /var/backups` |

### 3.1 Enabling systemd and cron in WSL2

Without systemd, `systemctl` is unavailable and the cron service must be started
manually (it may not survive a WSL restart).

```ini
# /etc/wsl.conf
[boot]
systemd=true
```

```powershell
wsl --shutdown
wsl -d Ubuntu
```

```bash
sudo apt update
sudo apt install -y cron tar gzip coreutils findutils util-linux
sudo systemctl enable --now cron
systemctl is-active cron        # expected: active
```

> ⚠️ On WSL2 without systemd: `sudo service cron start`. The daemon runs only while the
> distribution stays active. For persistent scheduling, prefer **Windows Task Scheduler**
> (`wsl.exe -d Ubuntu -- sudo /usr/local/sbin/backup.sh --quiet`) or a systemd timer.

### 3.2 Environment check

```bash
sudo ./backup.sh --dry-run
```

Expected output (excerpt):

```
[INFO] disk space: 3881 MB free, 609 MB required (sources ≈ 559 MB)
[INFO] [dry] would create /var/backups/lab06/backup-20261026-002038.tar.gz
[INFO] simulation complete — no changes made
```

---

## 4. Implementation

### 4.0 Repository layout

```
lab06-automated-backup/
├── README.md
├── backup.sh                      # standalone script (backup, retention, cron)
└── docs/
    └── screenshots/
        ├── 01-backup-run.png
        ├── 02-verify.png
        └── 03-cron-install.png
```

### 4.1 Configuration

Three layers, from lowest to highest priority:

1. **Script defaults** (below);
2. **Environment variables** (useful for cron and tests);
3. **CLI options** (`--dest`, `--retention`, …).

| Variable | Default | Purpose |
|----------|---------|---------|
| `BACKUP_DIR` | `/var/backups/lab06` | Archive destination |
| `BACKUP_LOG_FILE` | `/var/log/backup.log` | Run log |
| `BACKUP_SOURCES` | `/etc /var/log` | Directories to back up (space- or comma-separated) |
| `RETENTION_DAYS` | `7` | Retention period |
| `MIN_FREE_MB` | `200` | Minimum free space required |
| `CRON_TIME` | `02:15` | Daily job time |
| `ARCHIVE_PREFIX` | `backup` | Archive filename prefix |

```bash
# Example: extended backup, 14-day retention, dedicated destination
sudo BACKUP_SOURCES="/etc /var/log /home" \
     RETENTION_DAYS=14 \
     ./backup.sh --dest /srv/backups
```

> ⚠️ Avoid spaces in source paths: the list passed to cron is space-separated.

### 4.2 Backing up critical directories

```bash
sudo ./backup.sh
```

Internal sequence:

```bash
# 1) Effective sources (missing ones are skipped with a warning)
effective=(/etc /var/log)

# 2) Space check: du -sk estimate + 50 MB margin, MIN_FREE_MB floor
df -Pk /var/backups/lab06

# 3) Archive being written (never exposed)
tar -czpf /var/backups/lab06/backup-<ts>.tar.gz.partial.$$ \
    --numeric-owner \
    -C / etc \
    -C / var/log

# 4) Verification, then atomic publication
tar -tzf backup-<ts>.tar.gz.partial.$$
mv backup-<ts>.tar.gz.partial.$$ backup-<ts>.tar.gz
chmod 600 backup-<ts>.tar.gz
```

Key points:

- **Paths relative to `/`**: the archive contains `etc/…` and `var/log/…`, so it can be restored with `-C /`;
- **`--numeric-owner`**: preserves UID/GID regardless of account names;
- **Permissions**: directory `700`, archives `600 root:root` (they contain `/etc/shadow` and SSH host keys);
- **tar exit code 1** ("file changed as we read it") is tolerated and logged: live logs change during the read;
- **Optional exclusions** for large or volatile data:

```bash
sudo ./backup.sh --exclude 'var/log/journal/*' --exclude 'var/cache/*'
```

### 4.3 Disk space check

Before writing anything:

```bash
# Estimate source size
du -sk /etc /var/log

# Available space on the destination filesystem
df -Pk /var/backups/lab06 | awk 'NR==2 {print $4}'
```

Rule applied:

```
required = max( estimate + 50 MB , MIN_FREE_MB )
success  if free_space >= required
```

On failure, no archive is created and the exit code is `1`:

```
[INFO]  disk space: 180 MB free, 609 MB required (sources ≈ 559 MB)
[ERROR] insufficient space: 180 MB free < 609 MB required
[ERROR] backup cancelled: insufficient disk space
```

### 4.4 Automatic retention

After every successful backup:

```bash
find /var/backups/lab06 -maxdepth 1 -type f \
     -name 'backup-*.tar.gz' -mtime +7 -delete

# The matching checksum is removed in the same loop
rm -f backup-<old>.tar.gz.sha256
```

Deletion is **restricted to the pattern** `backup-*.tar.gz`: no other file in the directory
is touched. `.partial` files older than 24 hours are also cleaned up.

### 4.5 Logging

Every line is written to `/var/log/backup.log` **and** to the console (except with `--quiet`, used by cron):

```
2026-10-26 02:15:01 [INFO] === backup.sh v1.0.0 — mode: backup ===
2026-10-26 02:15:01 [INFO] lock acquired: /run/lock/lab06-backup.lock
2026-10-26 02:15:02 [INFO] disk space: 3881 MB free, 609 MB required (sources ≈ 559 MB)
2026-10-26 02:15:09 [OK]   archive integrity verified (tar -tzf)
2026-10-26 02:15:09 [OK]   SHA-256 checksum: backup-20261026-021500.tar.gz.sha256
2026-10-26 02:15:09 [OK]   archive created: /var/backups/lab06/backup-20261026-021500.tar.gz (12M)
2026-10-26 02:15:09 [INFO] retention: 1 archive(s) removed
2026-10-26 02:15:09 [OK]   backup completed in 8s
```

- Format: `YYYY-MM-DD HH:MM:SS [LEVEL] message`
- Levels: `INFO`, `OK`, `WARN`, `ERROR`
- Internal rotation at 5 MB (one generation kept)
- `logrotate` can take over if a centralized policy is preferred

### 4.6 Daily scheduling (`--install-cron`)

```bash
sudo ./backup.sh --install-cron              # daily at 02:15
sudo ./backup.sh --install-cron --cron-time 03:30
```

The mode performs four actions:

1. copies the script to `/usr/local/sbin/backup.sh` (mode `0750 root:root`);
2. prepares `/var/backups/lab06` (`700`) and `/var/log/backup.log` (`640`);
3. writes `/etc/cron.d/lab06-backup`:

```cron
# Lab 06 — Automated Backup System (generated by backup.sh v1.0.0)
# Daily backup: 02:15
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

BACKUP_DIR="/var/backups/lab06"
BACKUP_LOG_FILE="/var/log/backup.log"
RETENTION_DAYS="7"
MIN_FREE_MB="200"
BACKUP_SOURCES="/etc /var/log"

15 2 * * * root /usr/local/sbin/backup.sh --quiet
```

4. enables and starts the `cron` service (systemd or `service`).

```bash
# Verification
cat /etc/cron.d/lab06-backup
systemctl status cron --no-pager
sudo /usr/local/sbin/backup.sh --quiet     # immediate test run
grep CRON /var/log/syslog | tail           # or: journalctl -u cron -n 20
```

> 🔁 The script copied to `/usr/local/sbin` is the one cron executes. After editing
> `backup.sh`, rerun `--install-cron` to synchronize the copy.

**systemd alternative** (recommended when systemd is active):

```ini
# /etc/systemd/system/lab06-backup.service
[Unit]
Description=Lab 06 — automated backup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup.sh --quiet
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

```ini
# /etc/systemd/system/lab06-backup.timer
[Unit]
Description=Lab 06 — daily trigger

[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now lab06-backup.timer
systemctl list-timers lab06-backup.timer
```

### 4.7 Restore

**Inspect** before extracting anything:

```bash
sudo tar -tzf /var/backups/lab06/backup-20261026-021500.tar.gz | head -n 20
sudo tar -tzf /var/backups/lab06/backup-20261026-021500.tar.gz | grep 'etc/ssh/sshd_config'
```

**Selective restore** (safest):

```bash
# Extract into an isolated directory
sudo mkdir -p /tmp/restore/etc
sudo tar -xzf /var/backups/lab06/backup-20261026-021500.tar.gz \
     -C /tmp/restore etc/ssh/sshd_config

# Compare, then install the restored file
sudo diff -u /etc/ssh/sshd_config /tmp/restore/etc/ssh/sshd_config
sudo cp /tmp/restore/etc/ssh/sshd_config /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

**Full restore** (rescue environment or new machine):

```bash
# Verify integrity first
cd /var/backups/lab06 && sudo sha256sum -c backup-20261026-021500.tar.gz.sha256

# Extract into an isolated root, never directly onto a live system
sudo mkdir -p /mnt/restore
sudo tar -xzf backup-20261026-021500.tar.gz -C /mnt/restore
```

> 🚨 Never extract a dated archive directly into `/` on a production server: it would
> overwrite the current configuration (`/etc/shadow`, `/etc/fstab`, SSH keys…).

---

## 5. Testing

### 5.1 Test matrix

| # | Test | Command | Expected result |
|---|------|---------|-----------------|
| 1 | Simulation | `sudo ./backup.sh --dry-run` | No file created, plan displayed |
| 2 | Backup | `sudo ./backup.sh` | Archive + `.sha256`, exit code `0` |
| 3 | Permissions | `ls -l /var/backups/lab06` | `.tar.gz` as `-rw------- root root` |
| 4 | Contents | `tar -tzf <archive> \| head` | `etc/…`, `var/log/…` |
| 5 | Integrity | `sudo ./backup.sh --verify` | `SHA-256 valid`, `0 failure(s)` |
| 6 | Retention | aged archive + run | Old archive **and** its `.sha256` removed |
| 7 | Insufficient space | `sudo env MIN_FREE_MB=99999999 ./backup.sh --dry-run` | Exit `1`, explicit message, no archive |
| 8 | Lock | `flock /run/lock/lab06-backup.lock sleep 30` then run | Immediate refusal, exit `1` |
| 9 | Cron | `--install-cron` then inspect | `/etc/cron.d/lab06-backup` as expected |
| 10 | Log | `tail -n 20 /var/log/backup.log` | Timestamped lines, consistent levels |
| 11 | Invalid option | `sudo ./backup.sh --retention 0` | Exit `1` (business validation); unknown option → `2` |
| 12 | Help | `./backup.sh --help` | Full help, exit `0` |

### 5.2 Detailed checks

**Backup and integrity:**

```bash
sudo ./backup.sh
sudo ./backup.sh --list
sudo ./backup.sh --verify
```

```
DATE                     SIZE  ARCHIVE
2026-10-26 02:15           12M  backup-20261026-021500.tar.gz

1 archive(s) — retention: 7 day(s)
[OK] SHA-256 valid: backup-20261026-021500.tar.gz
[INFO] verification complete: 1 archive(s), 0 failure(s)
```

**Contents and metadata:**

```bash
arch="$(find /var/backups/lab06 -name 'backup-*.tar.gz' | sort | tail -n1)"
tar -tzf "$arch" | head -n 5
sudo stat -c '%A %U:%G %s %n' "$arch" "${arch}.sha256"
sudo sha256sum -c "${arch}.sha256"
```

**Retention simulation:**

```bash
# Create a fake archive dated 10 days ago
sudo touch -d '10 days ago' /var/backups/lab06/backup-20200101-000000.tar.gz
echo test | sudo tee /var/backups/lab06/backup-20200101-000000.tar.gz >/dev/null
sudo touch -d '10 days ago' /var/backups/lab06/backup-20200101-000000.tar.gz

sudo ./backup.sh
sudo ./backup.sh --list      # the 2020 archive is gone
```

**Disk space check:**

```bash
sudo env MIN_FREE_MB=99999999 ./backup.sh --dry-run
echo $?     # expected: 1
```

**Lock test:**

```bash
# Terminal 1
sudo flock /run/lock/lab06-backup.lock sleep 60

# Terminal 2
sudo ./backup.sh
# [ERROR] another backup is already running (lock: /run/lock/lab06-backup.lock)
```

**Cron test:**

```bash
sudo ./backup.sh --install-cron --cron-time 03:30
cat /etc/cron.d/lab06-backup
sudo /usr/local/sbin/backup.sh --quiet
sudo ./backup.sh --list
sudo journalctl -u cron --since '10 min ago' --no-pager
```

> 🧪 To avoid waiting until 03:30, schedule `--cron-time` for the next hour or run
> `/usr/local/sbin/backup.sh --quiet` directly (same path, same environment as cron).

### 5.3 Results observed in the lab

| Check | Observed result |
|-------|-----------------|
| Archive created | `backup-20261026-002144.tar.gz` (76 KB in the test container) |
| Permissions | `-rw------- root root` for the archive and its `.sha256` |
| Checksum | `SHA-256 valid` |
| Retention | 2020-dated archive removed, associated `.sha256` removed |
| Second run in the same second | `-1` suffix generated, no overwrite |
| Insufficient space | Exit code `1`, clear message, nothing written |
| Cron | File generated with `30 3 * * * root /usr/local/sbin/backup.sh --quiet` |
| Cron uninstall | `/etc/cron.d/lab06-backup` removed |

---

## 6. Troubleshooting

### 6.1 Quick diagnostic table

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No archive created | Insufficient space | `df -h`, purge old archives, adjust `MIN_FREE_MB` |
| `Permission denied` on `/etc/shadow` | Script not run as root | `sudo ./backup.sh` |
| `another backup is already running` | `flock` lock held | Wait, then check `lsof /run/lock/lab06-backup.lock` |
| `tar: file changed as we read it` | Live logs changing during the read | Normal (code 1 tolerated); exclude the files if needed |
| `gzip: unexpected end of file` | Truncated archive / full disk | Delete the invalid archive, rerun after freeing space |
| Cron does not run | Cron service stopped (WSL) | `sudo systemctl enable --now cron` or `sudo service cron start` |
| Cron runs but the log is empty | `--quiet` + failure before log init | Check `journalctl -u cron`, permissions on `/var/log` |
| `bad minute` / cron ignores the file | Invalid cron file or a dot in the name | Regenerate with `--install-cron`, name `lab06-backup` |
| Retention has no effect | Recent archives / manually changed mtime | `find … -mtime +7` only targets > 7 × 24 h |
| Log file empty | Permissions or custom path | `ls -l /var/log/backup.log`, check `BACKUP_LOG_FILE` |
| `command not found: tar` | Minimal image | `sudo apt install tar gzip` |
| Invalid checksum | Corrupted archive / partial copy | Restore from another archive, investigate the storage |
| `no existing source to back up` | Sources missing or misspelled | Check `--sources`, use absolute paths |

### 6.2 Cron inactive under WSL2

**Symptom**: `/etc/cron.d/lab06-backup` exists, but no daily backup runs.

**Diagnosis**:

```bash
pgrep -a cron || echo "cron is not running"
systemctl status cron --no-pager 2>/dev/null
service cron status
```

**Resolution**:

```bash
# With systemd
sudo systemctl enable --now cron

# Without systemd (classic WSL)
sudo service cron start
```

> ⚠️ Without systemd, cron stops when the WSL distribution stops (last window closed,
> `wsl --shutdown`). For reliable scheduling: enable systemd (Lab 05), or create a Windows task:
>
> ```powershell
> schtasks /Create /SC DAILY /ST 02:15 /TN "Lab06Backup" ^
>   /TR "wsl.exe -d Ubuntu -- sudo /usr/local/sbin/backup.sh --quiet" /RU SYSTEM
> ```

Also verify that the cron file is not being ignored:

```bash
ls -l /etc/cron.d/lab06-backup        # 644 root:root
grep -R "lab06" /etc/cron.d/
journalctl -u cron -n 50 --no-pager   # or grep CRON /var/log/syslog
```

### 6.3 "tar: file changed as we read it"

**Symptom**: the script logs `tar reported files changed while reading (code 1) — archive kept`.

**Cause**: `/var/log` contains continuously written files (syslog, auth.log, wtmp); tar detects
that their size or mtime changed between open and end of read.

**Script behavior**: code 1 is **tolerated**; the archive is kept after a successful `tar -tzf` check.

**Reduce the noise**:

```bash
sudo ./backup.sh --exclude 'var/log/journal/*' --exclude 'var/log/btmp'
```

> Code **2** (fatal) is never tolerated: the partial archive is deleted and the script fails.

### 6.4 Disk space check too strict

**Symptom**: `insufficient space` while `df` shows free capacity.

**Explanation**: the estimate uses `du -sk` (uncompressed size) + a 50 MB margin, with a
`MIN_FREE_MB` floor. A large `/var/log` can therefore require a lot of space.

**Fixes**:

```bash
# Lower the floor (the real estimate is still enforced)
sudo env MIN_FREE_MB=100 ./backup.sh

# Exclude large, low-value data
sudo ./backup.sh --exclude 'var/log/journal/*' --exclude 'var/cache/*'

# Clean old archives manually
sudo find /var/backups/lab06 -name 'backup-*.tar.gz' -mtime +30 -delete
```

### 6.5 Corrupted archive or invalid checksum

```bash
cd /var/backups/lab06
sudo sha256sum -c backup-20261026-021500.tar.gz.sha256
# backup-...tar.gz: FAILED
# sha256sum: WARNING: 1 computed checksum did NOT match
```

**Causes**: disk full during the write, abrupt shutdown, interrupted network copy, hardware corruption.

**Resolution**:

1. delete the invalid archive and its checksum;
2. run a new backup;
3. check `dmesg` (I/O errors) and `df -h`;
4. restore an earlier valid archive in the meantime.

> The script never publishes an archive whose `tar -tzf` check fails: this case should only
> appear after corruption **following** creation.

### 6.6 The log is not written

```bash
sudo ls -ld /var/log /var/log/backup.log
# expected: drwxr-x--- root syslog /var/log
#           -rw-r----- root root   /var/log/backup.log
```

- The script must run as root (or as a user with write access);
- If `BACKUP_LOG_FILE` points to a missing directory, `init_logging` creates it;
- If the disk is full, writes fail silently (the script continues): monitor `df`;
- With external rotation (`logrotate`), avoid stacking it on top of the internal 5 MB rotation.

### 6.7 Stale lock

A `flock` lock is released automatically when the file descriptor closes (process exit).
If it appears stuck:

```bash
sudo fuser -v /run/lock/lab06-backup.lock
sudo lsof /run/lock/lab06-backup.lock
ps aux | grep '[b]ackup.sh'
```

Deleting the lock **file** does not release a held lock: stop the process that owns it
(or wait). Never `kill -9` tar in production without checking that no archive is being published.

### 6.8 Cron runs the script but it fails

The cron environment is minimal. The generated file defines `SHELL`, `PATH`, `MAILTO=""`, and
all required variables. To diagnose:

```bash
# Reproduce the cron environment
sudo env -i SHELL=/bin/bash PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/local/sbin/backup.sh --quiet

# Trace execution
sudo grep CRON /var/log/syslog | tail -20
sudo journalctl -u cron -n 50 --no-pager
```

Common causes:

| Cause | Fix |
|-------|-----|
| script is not executable | `chmod 750 /usr/local/sbin/backup.sh` |
| path contains spaces | reinstall with `--install-cron` (copies to `/usr/local/sbin`) |
| cron is not running | `systemctl enable --now cron` |
| timezone mismatch | `timedatectl`, cron uses the system's local time |
| wrong `--cron-time` | regenerate: `sudo ./backup.sh --install-cron --cron-time HH:MM` |

### 6.9 Restore fails or paths are unexpected

```bash
tar -tzf archive.tar.gz | head
# etc/
# etc/hostname
# var/log/
```

Paths are **relative** (`etc/…`, `var/log/…`) because the archive is created with `tar -C /`.
Use `-C` when extracting:

```bash
sudo tar -xzf archive.tar.gz -C /tmp/restore
```

If an older archive contains absolute paths, extract with `--strip-components` or into an
isolated directory — never directly into `/`.

---

## 7. Lessons Learned

### 7.1 Principles retained

1. **An untested backup is not a backup.**
   Every archive is validated with `tar -tzf` **and** a SHA-256 checksum; a restore test
   should complement these checks at least once a quarter.
2. **Publish atomically, never progressively.**
   Writing to `.partial` and doing the final `mv` prevents a truncated archive from being
   mistaken for a valid one.
3. **Retention must be surgical.**
   `find` is restricted to the `backup-*.tar.gz` pattern: no foreign file can be deleted.
4. **Check disk space before, not during.**
   A `tar` that fills the disk can corrupt the archive **and** impact the system; an upfront
   check with margin is the simplest prevention.
5. **Permissions are security data.**
   `/etc/shadow` and host keys live inside the archive: `700` on the directory, `600` on files,
   and encryption is recommended for any off-site copy.
6. **A lock prevents silent conflicts.**
   Two simultaneous backups in the same directory produce inconsistent state; `flock` makes
   the second launch fail immediately and explicitly.
7. **Logs must be actionable.**
   Timestamps, levels, exit codes, and a final summary allow diagnosis without rereading the code.
8. **Cron is not magic.**
   Without a running service (common in WSL), the job exists only on paper; verify the daemon,
   the environment (`PATH`, `SHELL`), and the logs.

### 7.2 Technical takeaways

| Area | Key skill acquired |
|------|--------------------|
| Robust Bash | `set -Eeuo pipefail`, arrays, `trap ERR/EXIT`, logging functions |
| Archiving | `tar -czpf`, relative paths via `-C /`, `--numeric-owner`, exit codes 0/1/2 |
| Integrity | `tar -tzf`, `sha256sum`, verification before publication |
| Retention | `find -mtime +N`, paired archive + checksum deletion, `.partial` cleanup |
| Disk | `du -sk` + `df -Pk`, safety margin, configurable floor |
| Concurrency | `flock` on a file descriptor, automatic release at process exit |
| Scheduling | cron.d, environment variables, script copy, systemd timer alternative |
| Operations | logging, regression tests, documented restore procedure |
| Security | 700/600 permissions, least privilege, identified sensitive data |

### 7.3 Lab limitations and next steps

| Current limitation | Improvement |
|--------------------|-------------|
| Local backup only | **3-2-1 rule**: off-site copy (rsync/SFTP/S3) |
| Unencrypted archives | `age` or `gpg` before transfer, keys managed separately |
| Fixed retention | Grandfather-Father-Son (daily/weekly/monthly) |
| No deduplication | Migrate to **restic** or **borgbackup** for large volumes |
| No monitoring | Healthchecks.io, Prometheus textfile, alert on missing archive |
| No automated restore test | Quarterly extraction job + `diff` on reference files |
| No post-transfer verification | Remote checksum + comparison |
| Cron depends on the daemon | systemd timer with `Persistent=true` (catch-up after downtime) |

### 7.4 Operations checklist

- [x] Sources defined and justified (`/etc`, `/var/log`, documented extensions)
- [x] Dedicated destination, `700` permissions, `600 root:root` archives
- [x] Disk space check before writing
- [x] Atomic write (`.partial` → `.tar.gz`)
- [x] `tar -tzf` verification + SHA-256 checksum
- [x] Retention configured (7 days) and tested on an aged archive
- [x] Timestamped logging with rotation
- [x] Concurrency lock
- [x] Daily cron job installed, service active, test run successful
- [x] Restore procedure documented and tested
- [x] Off-site backup planned
- [x] Periodic restore test planned

### 7.5 Further reading

- [GNU tar manual](https://www.gnu.org/software/tar/manual/)
- [cron(8) — Ubuntu manual](https://manpages.ubuntu.com/manpages/noble/man8/cron.8.html)
- [systemd.timer manual](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [NIST SP 800-34 — Contingency Planning Guide](https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final)
- [restic](https://restic.net/) / [borgbackup](https://borgbackup.readthedocs.io/) — deduplicated, encrypted backups
- [The 3-2-1 backup rule](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/)

---

<p align="center">
  <em>Lab 06 — Automated Backup System · Ubuntu 24.04 LTS (WSL2) · Bash / tar / gzip / cron / systemd</em><br>
  Local lab environment — demonstration archives only.
</p>
