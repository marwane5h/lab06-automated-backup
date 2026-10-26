# Lab 06 — Automated Backup System

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?logo=ubuntu&logoColor=white&style=flat-square)
![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white&style=flat-square)
![tar + gzip](https://img.shields.io/badge/tar%20%2B%20gzip-Archives-A00000?style=flat-square)
![SHA-256](https://img.shields.io/badge/SHA--256-Verified-2ea44f?style=flat-square)
![cron](https://img.shields.io/badge/cron-Automated-6E4C13?style=flat-square)

## Overview

`backup.sh` gives a Linux server a backup routine that runs without an operator: it archives `/etc` and `/var/log`, checks free space first, and publishes an archive only after `tar -tzf` confirms it is readable and a SHA-256 fingerprint is recorded. Nothing half-written survives a failure — a botched run deletes its own partial file and leaves the previous backups untouched.

## Key System Features

| Feature | Technical Implementation | Operational Benefit |
|---|---|---|
| **Atomic Writes** | `tar` writes to `<archive>.partial.$$`; only after validation is it `mv`-ed into place, with `flock` blocking concurrent runs | Readers never see a truncated archive, and an interrupted job cannot leave a file that looks like a valid backup |
| **Pre-flight Disk Check** | `du -sk` source estimate + 50 MB margin, floored at `MIN_FREE_MB` (200 MB), compared against `df -Pk` on the destination | Refuses to start instead of filling the disk and taking the server down with the backup |
| **Integrity Verification** | `tar -tzf` before publication, then a `.sha256` sidecar; `--verify` re-checks every archive on demand | Corruption is caught at write time or during an audit — not halfway through a restore |
| **Retention Policy** | `find -mtime +7` restricted to `backup-*.tar.gz`, with each archive's `.sha256` deleted in the same loop | Storage stays bounded without ever touching files the script does not own |
| **Cron Automation** | `--install-cron` copies the script to `/usr/local/sbin`, writes `/etc/cron.d/lab06-backup`, and enables cron | The schedule lives in `/etc/cron.d`, not in someone's shell history, and the cron service is enabled in the same step |

The principle behind all five is the same: a backup is only worth something if you can trust it later. Each safeguard makes a bad archive fail loudly now rather than silently during a restore.

A fatal `tar` error exits non-zero and removes the partial file; the one tolerated exception is exit code 1 (a live log changed mid-read), which is logged and still subjected to the integrity check.

## Quick Start

```bash
git clone https://github.com/marwane5h/lab06-automated-backup.git
cd lab06-automated-backup
chmod +x backup.sh
sudo ./backup.sh --dry-run
sudo ./backup.sh
```

Defaults are `/etc` and `/var/log` → `/var/backups/lab06`, 7-day retention, a 200 MB free-space floor, and a daily run at 02:15. Override them with `--sources`, `--dest`, `--retention`, `--min-free`, and `--cron-time`.

It must run as root: it reads `/etc/shadow` and writes to `/var/log` and `/var/backups`.

When the dry run looks right, schedule it:

```bash
sudo ./backup.sh --install-cron
# 15 2 * * * root /usr/local/sbin/backup.sh --quiet
```

## Verification & Evidence

```console
$ sudo ./backup.sh --list
DATE                       SIZE  ARCHIVE
2026-10-26 02:15           76K  backup-20261026-021500.tar.gz

1 archive(s) — retention: 7 day(s)

$ sudo ./backup.sh --verify
[INFO] === backup.sh v1.0.0 — mode: verify ===
[INFO] verifying archives in /var/backups/lab06
[OK] SHA-256 valid: backup-20261026-021500.tar.gz
[INFO] verification complete: 1 archive(s), 0 failure(s)
```

## Key Engineering Takeaways

- **Atomic operations over heroics.** Writing to a `.partial` file and renaming only after validation means the recovery plan is built into the write path, not into someone's memory at 3 a.m.
- **Verify before you trust.** `tar -tzf` at creation and SHA-256 on demand turn "the backup exists" into "the backup is usable" — the only claim that matters during an incident.
- **Let the lifecycle run itself.** Retention, logging, and cron are part of the tool, not a wiki page, so storage stays bounded and the schedule survives handovers and busy weeks.
