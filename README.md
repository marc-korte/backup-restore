# backup_restore.sh

A cross-distribution backup and restore utility for Linux systems.

## Features

- **Multi-distribution support**: Fedora, Ubuntu/Debian, openSUSE (including Leap 16+)
- **restic-based home backups** (preferred): deduplicated, compressed, encrypted snapshots with built-in integrity verification — fast even over CIFS/NAS
- **Legacy fallback**: rsync with hard-links (local) or tar archives (CIFS) when restic is not available
- **Smart retention policy**: snapshot pruning via restic (daily/weekly/monthly), plus disk-space management for legacy backup directories
- **Checksum verification**: `restic check` after every backup; SHA256 checksums for legacy/metadata files
- **Flatpak support**: Backs up and restores Flatpak applications
- **Package management**: Exports and restores system packages per distribution
- **Systemd integration**: Can set up automated backups with systemd timers
- **Dry-run mode**: Test operations without making changes
- **Selective restore**: Choose which components to restore

## Installation

### Quick Start

```bash
# Clone or download the script
git clone https://github.com/luna-co-software/backup-restore
cd backup-restore

# Make it executable
chmod +x backup_restore.sh

# Run the setup wizard
./backup_restore.sh init

# Create your first backup
./backup_restore.sh backup
```

### System-wide Installation

```bash
# Copy to system location
sudo cp backup_restore.sh /usr/local/sbin/
sudo chmod 750 /usr/local/sbin/backup_restore.sh

# Create system-wide config (optional)
sudo mkdir -p /etc/backup-restore
sudo cp config.example /etc/backup-restore/config
sudo chmod 600 /etc/backup-restore/config
```

## Configuration

### Setup Wizard

The easiest way to configure the script is using the interactive setup wizard:

```bash
./backup_restore.sh init
```

This creates a configuration file at `~/.config/backup-restore/config`.

### Configuration File Locations

The script looks for configuration in these locations (in order of precedence):

1. `$CONFIG_FILE` environment variable
2. `~/.config/backup-restore/config` (user config)
3. `/etc/backup-restore/config` (system config)

### Configuration Options

```bash
# User to backup
USER_NAME="username"
HOME_DIR="/home/username"

# Backup destination
MOUNT_BASE="/mnt/backup"

# Retention policy
MIN_FREE_SPACE_GB="50"      # Minimum free space to maintain
MIN_BACKUPS_TO_KEEP="3"     # Never delete below this count
MAX_BACKUPS="30"            # Maximum backups to keep

# fstab management
BACKUP_FSTAB_ENABLED="true"
BACKUP_MOUNT_POINT="/mnt/backup"
BACKUP_FSTAB_OPTIONS="ext4  nofail,x-systemd.automount,x-systemd.idle-timeout=60  0  2"

# NAS/CIFS configuration (optional)
NAS_ENABLED="false"
NAS_SHARE="//nas.local/share"
NAS_MOUNT_POINT="/mnt/nas"
NAS_CREDENTIALS_FILE="/home/username/.config/backup-restore/nas.cred"

# restic configuration (used automatically when restic is installed
# and the password file exists)
RESTIC_ENABLED="true"
RESTIC_REPO="$MOUNT_BASE/restic-repo"
RESTIC_PASSWORD_FILE="/etc/backup-restore/restic.pass"
RESTIC_KEEP_DAILY="7"
RESTIC_KEEP_WEEKLY="4"
RESTIC_KEEP_MONTHLY="6"

# Custom exclusions (optional)
EXCLUDE=(
  "--exclude=.cache"
  "--exclude=.local/share/Trash"
  "--exclude=.local/share/Steam"
  "--exclude=Downloads"
  "--exclude=*.tmp"
  "--exclude=*.bak"
)
```

### Environment Variables

All configuration options can also be set via environment variables:

```bash
MOUNT_BASE=/mnt/external ./backup_restore.sh backup
DRY_RUN=true ./backup_restore.sh backup
```

## Usage

### Commands

```bash
# Interactive setup wizard
./backup_restore.sh init

# Create a backup
./backup_restore.sh backup

# Test backup without making changes
./backup_restore.sh --dry-run backup

# Restore from latest backup (full restore)
sudo ./backup_restore.sh restore

# Selective restore (choose components)
sudo ./backup_restore.sh --selective restore

# Interactive menu
./backup_restore.sh menu

# Show help
./backup_restore.sh help

# Show version
./backup_restore.sh --version
```

### What Gets Backed Up

1. **Home directory** (`/home/username/`)
   - **restic** (preferred): deduplicated, compressed, encrypted snapshots in
     `$RESTIC_REPO`. Only changed data is uploaded after the first run, so
     nightly backups take minutes instead of hours. `--one-file-system` keeps
     FUSE mounts (e.g. rclone cloud mounts) out of the snapshot.
   - Legacy fallback when restic is unavailable: rsync with hard-links on
     local filesystems, tar archive on CIFS/NAS mounts
   - Preserves permissions, xattrs, ACLs, and SELinux contexts

2. **Package list** (`packages.txt`)
   - Fedora: user-installed packages via dnf5/dnf
   - Ubuntu: manually installed packages via apt-mark
   - openSUSE: installed packages via zypper

3. **Repository configuration** (`repos_and_keys.tar.gz`)
   - Fedora: `/etc/yum.repos.d/` and GPG keys
   - Ubuntu: APT sources and keyrings
   - openSUSE: zypper repos and GPG keys

4. **Flatpak applications** (`flatpaks.txt`)
   - List of installed Flatpak applications

5. **Systemd units** (optional)
   - Backup service and timer configurations
   - The backup script itself

### Restore Options

When using `--selective`, you can choose to restore:

1. **Packages only** - Reinstall system packages
2. **Home directory only** - Restore user files (from the latest restic
   snapshot when a repository exists; otherwise from the legacy tar/rsync
   backup)
3. **Flatpaks only** - Reinstall Flatpak applications
4. **System config** - Repos, systemd units, fstab entries
5. **Everything** - Full restore
6. **Custom selection** - Pick individual components

## Automated Backups with Systemd

### Create the Service Unit

Create `/etc/systemd/system/home-backup.service`:

```ini
[Unit]
Description=Home Directory Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup_restore.sh backup
User=root
Nice=19
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
```

### Create the Timer Unit

Create `/etc/systemd/system/home-backup.timer`:

```ini
[Unit]
Description=Daily Home Backup Timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

### Enable the Timer

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now home-backup.timer

# Check timer status
systemctl list-timers home-backup.timer

# View logs
journalctl -u home-backup.service
```

## restic Setup

restic is the preferred backup engine. To enable it:

```bash
# Install restic (openSUSE: zypper, Fedora: dnf, Ubuntu/Debian: apt)
sudo zypper install restic

# Create the repository password file
sudo mkdir -p /etc/backup-restore
sudo sh -c 'openssl rand -base64 32 > /etc/backup-restore/restic.pass && chmod 600 /etc/backup-restore/restic.pass'
```

The script detects restic + password file automatically and initializes the
repository on first backup. No other setup needed.

> **WARNING:** The restic repository is encrypted with this password. If the
> password file is lost, all backups become permanently unreadable. Store a
> copy of the password in a password manager or other safe location that does
> not live on the machine being backed up.

After every backup the script runs `restic forget` (retention) and
`restic check` (integrity verification) automatically.

### Useful restic commands

```bash
export RESTIC_REPOSITORY=/mnt/backup/restic-repo
export RESTIC_PASSWORD_FILE=/etc/backup-restore/restic.pass

sudo -E restic snapshots          # list all snapshots
sudo -E restic ls latest          # list files in the latest snapshot
sudo -E restic mount /mnt/restic  # browse snapshots as a filesystem
sudo -E restic restore latest --target / --path /home/username  # restore home
sudo -E restic check --read-data-subset=5%  # deep integrity check (slow)
```

## Smart Retention Policy

**restic snapshots** are pruned after every backup according to
`RESTIC_KEEP_DAILY` / `RESTIC_KEEP_WEEKLY` / `RESTIC_KEEP_MONTHLY`
(defaults: 7 daily, 4 weekly, 6 monthly).

**Legacy backup directories** (and the small per-run metadata directories)
are managed separately:

1. **Maximum limit**: Removes oldest backups when `MAX_BACKUPS` is exceeded
2. **Space management**: Removes oldest backups to maintain `MIN_FREE_SPACE_GB`
3. **Minimum protection**: Never deletes below `MIN_BACKUPS_TO_KEEP`

Example with defaults:
- Keeps at least 3 backups
- Keeps at most 30 backups
- Maintains at least 50GB free space

## NAS/CIFS Setup

### Configure NAS Mount

1. Enable NAS in your config:
   ```bash
   NAS_ENABLED="true"
   NAS_SHARE="//truenas.local/Backups"
   NAS_MOUNT_POINT="/mnt/nas"
   NAS_CREDENTIALS_FILE="~/.config/backup-restore/nas.cred"
   ```

2. Create credentials file:
   ```bash
   mkdir -p ~/.config/backup-restore
   cat > ~/.config/backup-restore/nas.cred << EOF
   username=your_nas_username
   password=your_nas_password
   EOF
   chmod 600 ~/.config/backup-restore/nas.cred
   ```

3. The script will automatically:
   - Install `cifs-utils` if needed
   - Add entries to `/etc/fstab` (with your approval)
   - Create mount points
   - Use tar archives to preserve metadata on CIFS

## Supported Distributions

| Distribution | Package Manager | Tested |
|-------------|-----------------|--------|
| Fedora 39+ | dnf5/dnf | Yes |
| RHEL/CentOS 8+ | dnf | Yes |
| Rocky/AlmaLinux | dnf | Yes |
| Ubuntu 20.04+ | apt | Yes |
| Debian 11+ | apt | Yes |
| Linux Mint | apt | Yes |
| Pop!_OS | apt | Yes |
| openSUSE Leap 15+ | zypper | Yes |
| openSUSE Tumbleweed | zypper | Yes |
| SLES | zypper | Yes |

## Troubleshooting

### Backup fails with "mount not found"

Ensure your backup destination is mounted:
```bash
mount /mnt/backup
# or check fstab and run
sudo systemctl daemon-reload
```

### Permission denied errors

For system restore operations, run with sudo:
```bash
sudo ./backup_restore.sh restore
```

### Checksum verification fails

This indicates potential backup corruption. Options:
1. Try restoring from a different backup
2. Run `./backup_restore.sh menu` and use option 4 to verify checksums
3. Check disk health on backup media

### restic check reports errors

```bash
sudo -E restic check --read-data-subset=5%   # verify a sample of actual data
sudo -E restic repair index                  # rebuild a damaged index
```
If errors persist, check the storage backend (NAS disk health, network share
integrity) before trusting further backups.

### Lost restic password

There is no recovery. The repository is encrypted and unreadable without the
password file. Start a new repository (`restic init` happens automatically on
the next backup after you create a new password file) and treat the old one
as lost.

### SELinux contexts not preserved

The script automatically detects SELinux and uses appropriate flags. If contexts are wrong after restore:
```bash
sudo restorecon -Rv /home/username
```

## Requirements

- bash 4.0+
- coreutils (standard Linux utilities)
- tar
- findutils
- One of: dnf5/dnf, apt, or zypper (depending on distribution)
- **Recommended: restic** (preferred backup engine for the home directory)
- Optional: rsync (legacy fallback), flatpak, cifs-utils (for NAS)

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request
