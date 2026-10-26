# Lab 06 — Automated Backup System

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?logo=ubuntu&logoColor=white&style=flat-square)
![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white&style=flat-square)
![tar + gzip](https://img.shields.io/badge/tar%20%2B%20gzip-Archives-A00000?style=flat-square)
![SHA-256](https://img.shields.io/badge/SHA--256-Verified-2ea44f?style=flat-square)
![cron](https://img.shields.io/badge/cron-Automated-6E4C13?style=flat-square)

## Overview

`backup.sh` backs up `/etc` and `/var/log` into timestamped `.tar.gz` files. It checks free space, verifies each new archive, removes old copies, and can run daily from cron, so backups stay reliable without manual work.

## Key Features

| Feature | How it works | Why it matters |
|---|---|---|
| **Safe file creation** | The script writes to a `.partial` file first. It renames the file only after the archive passes its checks. | A failed run cannot leave a broken file that looks like a good backup. |
| **Disk space check** | It measures the source size, adds a 50 MB margin, and checks free space. It stops if space is too low (200 MB minimum). | The backup stops before it fills the disk. |
| **Integrity check** | It tests the archive with `tar -tzf` before keeping it. It also saves a SHA-256 hash next to each archive. | You can prove the file is readable and has not changed. |
| **Automatic cleanup** | It deletes `backup-*.tar.gz` files older than 7 days. Their hash files are deleted too. | Old backups do not fill the disk forever. |
| **Automatic schedule** | `--install-cron` copies the script to `/usr/local/sbin` and adds a daily job at 02:15. | Backups run every day without anyone starting them. |

## Quick Start

```bash
git clone https://github.com/marwane5h/lab06-automated-backup.git
cd lab06-automated-backup
chmod +x backup.sh
sudo ./backup.sh --dry-run
sudo ./backup.sh
```

`--dry-run` shows the plan and writes no archive. To run the backup every day, use `sudo ./backup.sh --install-cron`.

By default, archives go to `/var/backups/lab06`, and the log is `/var/log/backup.log`. Use `--dest` to pick another folder.

## Verification

Run these after a backup:

```console
$ sudo ./backup.sh --list
DATE                       SIZE  ARCHIVE
2026-10-26 02:15           76K  backup-20261026-021500.tar.gz

1 archive(s) — retention: 7 day(s)

$ sudo ./backup.sh --verify
[INFO] verifying archives in /var/backups/lab06
[OK] SHA-256 valid: backup-20261026-021500.tar.gz
[INFO] verification complete: 1 archive(s), 0 failure(s)
```

## Key Takeaways

- **A backup must be complete before you trust it.** The `.partial` file and final rename stop a failed run from looking successful.
- **A file name is not proof.** `tar -tzf` and SHA-256 show that the archive is readable and unchanged.
- **Routine work should run itself.** Retention keeps the folder small, and cron keeps backups on schedule.
