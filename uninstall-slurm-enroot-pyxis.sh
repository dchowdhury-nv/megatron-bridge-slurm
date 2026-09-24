#!/usr/bin/env bash
# Cleanly remove the stack installed by setup-slurm-enroot-pyxis.sh.
set -Eeuo pipefail

ASSUME_YES=0
KEEP_DATA=0
SKIP_BACKUP=0

log()  { printf '\n[uninstall] %s\n' "$*"; }
warn() { printf '\n[warning] %s\n' "$*" >&2; }
die()  { printf '\n[error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo ./uninstall-slurm-enroot-pyxis.sh [options]

Options:
  --yes          Do not ask for confirmation
  --keep-data    Remove software but retain /etc/slurm, /etc/munge and Slurm state
  --skip-backup  Do not create a backup before removal
  -h, --help     Show this help

Default behavior:
  * Stops and disables slurmctld, slurmd, slurmdbd and munge when present.
  * Saves configuration and Slurm state to a mode-0600 archive under /root.
  * Purges slurm-smd*, Enroot, and MUNGE packages.
  * Removes the locally installed Pyxis plugin and installer build cache.
  * Removes Slurm configuration/state and the generated cluster bundle.
  * Does not delete Enroot images or containers stored in users' home directories.
EOF
}

while (($#)); do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        --keep-data) KEEP_DATA=1; shift ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

((EUID == 0)) || die "Run this uninstaller as root, for example: sudo $0"

source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || \
    die "This script supports Ubuntu 24.04 only; found ${PRETTY_NAME:-unknown}."

cluster_name=""
if [[ -r /etc/slurm/slurm.conf ]]; then
    cluster_name=$(awk -F= '$1=="ClusterName" {print $2; exit}' /etc/slurm/slurm.conf)
fi
[[ -z $cluster_name || $cluster_name =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "Refusing to use unsafe ClusterName from /etc/slurm/slurm.conf"

mapfile -t slurm_packages < <(
    dpkg-query -W -f='${binary:Package}\n' 'slurm-smd*' 2>/dev/null | sort -u || true
)

printf 'This will remove:\n'
printf '  - Slurm packages: %s\n' "${slurm_packages[*]:-(none found)}"
printf '  - Enroot packages and system configuration\n'
printf '  - Pyxis under /usr/local/lib/slurm and /usr/local/share/pyxis\n'
printf '  - MUNGE package and key\n'
if ((KEEP_DATA)); then
    printf 'Slurm and MUNGE configuration/state will be retained (--keep-data).\n'
else
    printf 'Slurm and MUNGE configuration/state will be removed after backup.\n'
fi

if ((ASSUME_YES == 0)); then
    read -r -p 'Type DELETE to continue: ' confirmation
    [[ $confirmation == DELETE ]] || die "Uninstall cancelled"
fi

log "Stopping and disabling cluster services"
for service in slurmctld slurmd slurmdbd munge; do
    if systemctl cat "${service}.service" >/dev/null 2>&1; then
        systemctl disable --now "$service" 2>/dev/null || \
            warn "Could not completely stop or disable $service"
    fi
done

backup=""
if ((SKIP_BACKUP == 0)); then
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup="/root/slurm-stack-backup-${timestamp}.tar.gz"
    backup_items=()
    for path in \
        /etc/slurm \
        /etc/munge \
        /var/spool/slurmctld \
        /var/spool/slurmd \
        /var/log/slurm; do
        [[ -e $path ]] && backup_items+=("${path#/}")
    done
    if [[ -n $cluster_name && -f /root/${cluster_name}-slurm-bootstrap.tar.gz ]]; then
        backup_items+=("root/${cluster_name}-slurm-bootstrap.tar.gz")
    fi

    if ((${#backup_items[@]})); then
        log "Backing up configuration and state to $backup"
        umask 077
        tar -czf "$backup" -C / "${backup_items[@]}"
        chmod 0600 "$backup"
    else
        warn "No configuration or state was found to back up"
        backup=""
    fi
fi

log "Removing Pyxis"
rm -f \
    /etc/slurm/plugstack.conf.d/pyxis.conf \
    /usr/local/lib/slurm/spank_pyxis.so
rm -rf /usr/local/share/pyxis
rmdir /usr/local/lib/slurm 2>/dev/null || true

log "Purging installed packages"
packages_to_purge=("${slurm_packages[@]}")
for package in 'enroot+caps' enroot enroot-hardened 'enroot-hardened+caps' munge libmunge-dev; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
        packages_to_purge+=("$package")
    fi
done
if ((${#packages_to_purge[@]})); then
    if ((KEEP_DATA)); then
        apt-get remove -y "${packages_to_purge[@]}"
    else
        apt-get purge -y "${packages_to_purge[@]}"
    fi
else
    warn "No matching Debian packages were installed"
fi

if ((KEEP_DATA == 0)); then
    log "Removing Slurm/MUNGE configuration and service state"
    rm -rf \
        /etc/slurm \
        /etc/munge \
        /var/spool/slurmctld \
        /var/spool/slurmd \
        /var/log/slurm \
        /run/slurmctld.pid \
        /run/slurmd.pid

    if [[ -n $cluster_name ]]; then
        rm -f "/root/${cluster_name}-slurm-bootstrap.tar.gz"
    fi
fi

log "Removing installer build cache and system-level Enroot cache"
rm -rf \
    /var/tmp/slurm-stack-build \
    /var/cache/enroot \
    /run/enroot

# Package scripts normally remove service accounts. Remove them only when they
# still exist, have no running processes, and this uninstall is deleting data.
if ((KEEP_DATA == 0)); then
    for account in slurm munge; do
        if getent passwd "$account" >/dev/null; then
            if pgrep -u "$account" >/dev/null 2>&1; then
                warn "Retaining account '$account' because it still owns running processes"
            else
                userdel "$account" 2>/dev/null || warn "Could not remove account '$account'"
                if getent group "$account" >/dev/null; then
                    groupdel "$account" 2>/dev/null || warn "Could not remove group '$account'"
                fi
            fi
        fi
    done
fi

systemctl daemon-reload

printf '\nUninstall complete.\n'
if [[ -n $backup ]]; then
    printf 'Backup: %s\n' "$backup"
fi
printf 'User-owned Enroot images and containers under home directories were not removed.\n'
printf 'Build tools and shared dependencies were retained because they may be used by other software.\n'
