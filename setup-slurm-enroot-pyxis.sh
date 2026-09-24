#!/usr/bin/env bash
# Ubuntu 24.04 bootstrap for Slurm 24.11.7, Enroot 4.1.2 and Pyxis 0.20.0.
# Run on the controller first, then copy the generated root-only bundle to workers.
set -Eeuo pipefail

SLURM_VERSION="24.11.7"
ENROOT_VERSION="4.1.2"
PYXIS_VERSION="0.20.0"
BUILD_ROOT="/var/tmp/slurm-stack-build"
ROLE=""
CLUSTER_NAME=""
CONTROLLER=""
COMPUTE_NODES=""
CPUS_PER_NODE=""
REAL_MEMORY_MB=""
GPUS_PER_NODE=""
MUNGE_KEY_SOURCE=""
CLUSTER_BUNDLE=""
EXTERNAL_SLURMDBD=""
NON_INTERACTIVE=0

log()  { printf '\n[setup] %s\n' "$*"; }
warn() { printf '\n[warning] %s\n' "$*" >&2; }
die()  { printf '\n[error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo ./setup-slurm-enroot-pyxis.sh [options]

Interactive mode asks for everything. For automation:
  --role controller|compute|both
  --cluster-name NAME
  --controller HOSTNAME_OR_IP
  --compute-nodes NODE1[,NODE2,...]
  --cpus-per-node N          Manual override; requires all three resource options
  --real-memory-mb N         Manual override; otherwise each node is probed
  --gpus-per-node N          Manual override; otherwise every GPU is detected
  --cluster-bundle FILE       Required on compute-only nodes unless config/key exist
  --munge-key-file FILE       Alternative to a cluster bundle
  --external-slurmdbd HOST    Optional shared SlurmDBD for multi-cluster visibility
  --non-interactive

Examples:
  # First, on exp-blr-login:
  sudo ./setup-slurm-enroot-pyxis.sh --role controller \
    --cluster-name exp-blr --controller exp-blr-login \
    --compute-nodes exp-blr-dgxb200-01

  # Copy /root/exp-blr-slurm-bootstrap.tar.gz securely, then on the B200:
  sudo ./setup-slurm-enroot-pyxis.sh --role compute \
    --cluster-bundle /root/exp-blr-slurm-bootstrap.tar.gz

Notes:
  * Node names must resolve consistently on every host (DNS or /etc/hosts).
  * Users/groups and clocks must be synchronized across all nodes.
  * The generated bundle contains the secret MUNGE key; protect and delete copies.
EOF
}

while (($#)); do
    case "$1" in
        --role) ROLE="${2:?}"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="${2:?}"; shift 2 ;;
        --controller) CONTROLLER="${2:?}"; shift 2 ;;
        --compute-nodes) COMPUTE_NODES="${2:?}"; shift 2 ;;
        --cpus-per-node) CPUS_PER_NODE="${2:?}"; shift 2 ;;
        --real-memory-mb) REAL_MEMORY_MB="${2:?}"; shift 2 ;;
        --gpus-per-node) GPUS_PER_NODE="${2:?}"; shift 2 ;;
        --cluster-bundle) CLUSTER_BUNDLE="${2:?}"; shift 2 ;;
        --munge-key-file) MUNGE_KEY_SOURCE="${2:?}"; shift 2 ;;
        --external-slurmdbd) EXTERNAL_SLURMDBD="${2:?}"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

((EUID == 0)) || die "Run this installer as root, for example: sudo $0"

source /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || \
    die "This script supports Ubuntu 24.04 only; found ${PRETTY_NAME:-unknown}."

prompt_default() {
    local var_name=$1 prompt=$2 default=$3 value
    if [[ -n ${!var_name} ]]; then return; fi
    ((NON_INTERACTIVE == 0)) || die "Missing required option for: $prompt"
    read -r -p "$prompt [$default]: " value
    printf -v "$var_name" '%s' "${value:-$default}"
}

if [[ -z $ROLE ]]; then
    ((NON_INTERACTIVE == 0)) || die "--role is required"
    printf 'Node role:\n  1) bastion/controller\n  2) compute\n  3) both\n'
    read -r -p 'Choose 1, 2, or 3: ' role_choice
    case "$role_choice" in
        1) ROLE=controller ;; 2) ROLE=compute ;; 3) ROLE=both ;;
        *) die "Invalid role" ;;
    esac
fi
[[ $ROLE =~ ^(controller|compute|both)$ ]] || die "Invalid --role: $ROLE"

is_controller=0; is_compute=0
[[ $ROLE == controller || $ROLE == both ]] && is_controller=1
[[ $ROLE == compute || $ROLE == both ]] && is_compute=1

if [[ -n $CLUSTER_BUNDLE ]]; then
    [[ -f $CLUSTER_BUNDLE ]] || die "Bundle not found: $CLUSTER_BUNDLE"
    bundle_dir=$(mktemp -d)
    trap 'rm -rf "$bundle_dir"' EXIT
    tar -xzf "$CLUSTER_BUNDLE" -C "$bundle_dir"
    [[ -f $bundle_dir/slurm.conf && -f $bundle_dir/munge.key ]] || \
        die "Invalid bundle: slurm.conf or munge.key is missing"
    CLUSTER_NAME=$(awk -F= '$1=="ClusterName" {print $2; exit}' "$bundle_dir/slurm.conf")
    CONTROLLER=$(awk -F= '$1=="SlurmctldHost" {print $2; exit}' "$bundle_dir/slurm.conf")
    MUNGE_KEY_SOURCE="$bundle_dir/munge.key"
fi

if ((is_controller)); then
    prompt_default CLUSTER_NAME 'Cluster name' 'exp-blr'
    prompt_default CONTROLLER 'Controller hostname or IP' "$(hostname -s)"
    if ((is_compute)); then
        prompt_default COMPUTE_NODES 'Comma-separated compute node hostnames' "$(hostname -s)"
    else
        prompt_default COMPUTE_NODES 'Comma-separated compute node hostnames' 'exp-blr-dgxb200-01'
    fi

    manual_values=0
    [[ -n $CPUS_PER_NODE ]] && ((manual_values += 1))
    [[ -n $REAL_MEMORY_MB ]] && ((manual_values += 1))
    [[ -n $GPUS_PER_NODE ]] && ((manual_values += 1))
    ((manual_values == 0 || manual_values == 3)) || \
        die "Specify all three manual resource options, or none to auto-detect each node"
    if ((manual_values == 3)); then
        [[ $CPUS_PER_NODE =~ ^[1-9][0-9]*$ ]] || die "CPU count must be a positive integer"
        [[ $REAL_MEMORY_MB =~ ^[1-9][0-9]*$ ]] || die "Memory must be a positive integer"
        [[ $GPUS_PER_NODE =~ ^[0-9]+$ ]] || die "GPU count must be an integer"
    fi
elif [[ -z $CLUSTER_BUNDLE ]]; then
    [[ -f /etc/slurm/slurm.conf && -f /etc/munge/munge.key ]] || \
        die "Compute nodes need --cluster-bundle from the controller (recommended), or existing /etc/slurm/slurm.conf and /etc/munge/munge.key."
fi

safe_name_re='^[A-Za-z0-9._-]+$'
[[ -z $CLUSTER_NAME || $CLUSTER_NAME =~ $safe_name_re ]] || die "Unsafe cluster name"
[[ -z $CONTROLLER || $CONTROLLER =~ $safe_name_re ]] || die "Unsafe controller name/address"
if [[ -n $COMPUTE_NODES ]]; then
    IFS=',' read -r -a node_array <<< "$COMPUTE_NODES"
    ((${#node_array[@]} > 0)) || die "At least one compute node is required"
    for node in "${node_array[@]}"; do
        [[ $node =~ $safe_name_re ]] || die "Unsafe compute node name: $node"
    done
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing operating-system prerequisites"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl devscripts equivs fakeroot git \
    gawk jq libcap2-bin libmunge-dev munge parallel pkg-config \
    squashfs-tools xz-utils

install_slurm() {
    if command -v scontrol >/dev/null 2>&1 && \
       scontrol --version 2>/dev/null | grep -q "slurm ${SLURM_VERSION}"; then
        log "Slurm ${SLURM_VERSION} is already installed"
        return
    fi

    log "Building upstream Slurm ${SLURM_VERSION} Debian packages (this can take several minutes)"
    rm -rf "$BUILD_ROOT/slurm"; install -d "$BUILD_ROOT/slurm"
    curl --fail --location --retry 3 \
        "https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2" \
        -o "$BUILD_ROOT/slurm/slurm.tar.bz2"
    tar -xjf "$BUILD_ROOT/slurm/slurm.tar.bz2" -C "$BUILD_ROOT/slurm"
    pushd "$BUILD_ROOT/slurm/slurm-${SLURM_VERSION}" >/dev/null
    mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control
    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" debuild -b -uc -us
    popd >/dev/null

    mapfile -t common_debs < <(find "$BUILD_ROOT/slurm" -maxdepth 1 -type f \
        \( -name 'slurm-smd_[0-9]*.deb' -o -name 'slurm-smd-client_[0-9]*.deb' \
           -o -name 'slurm-smd-dev_[0-9]*.deb' \) -print)
    ((${#common_debs[@]} >= 2)) || die "Could not find the built Slurm common packages"
    apt-get install -y "${common_debs[@]}"

    if ((is_controller)); then
        controller_deb=$(find "$BUILD_ROOT/slurm" -maxdepth 1 -type f -name 'slurm-smd-slurmctld_[0-9]*.deb' -print -quit)
        [[ -n $controller_deb ]] || die "Built slurmctld package was not found"
        apt-get install -y "$controller_deb"
    fi
    if ((is_compute)); then
        compute_deb=$(find "$BUILD_ROOT/slurm" -maxdepth 1 -type f -name 'slurm-smd-slurmd_[0-9]*.deb' -print -quit)
        [[ -n $compute_deb ]] || die "Built slurmd package was not found"
        apt-get install -y "$compute_deb"
    fi
}

install_enroot() {
    if command -v enroot >/dev/null 2>&1 && enroot version 2>/dev/null | grep -q "$ENROOT_VERSION"; then
        log "Enroot ${ENROOT_VERSION} is already installed"
        return
    fi
    log "Installing Enroot ${ENROOT_VERSION}"
    local arch url_base enroot_deb caps_deb
    arch=$(dpkg --print-architecture)
    [[ $arch == amd64 || $arch == arm64 ]] || die "Unsupported architecture for Enroot packages: $arch"
    install -d "$BUILD_ROOT/enroot"
    url_base="https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}"
    enroot_deb="$BUILD_ROOT/enroot/enroot_${ENROOT_VERSION}-1_${arch}.deb"
    caps_deb="$BUILD_ROOT/enroot/enroot+caps_${ENROOT_VERSION}-1_${arch}.deb"
    curl --fail --location --retry 3 "$url_base/$(basename "$enroot_deb")" -o "$enroot_deb"
    curl --fail --location --retry 3 "$url_base/$(basename "$caps_deb")" -o "$caps_deb"
    apt-get install -y "$enroot_deb" "$caps_deb"
}

install_pyxis() {
    local plugin=/usr/local/lib/slurm/spank_pyxis.so
    if [[ -f $plugin ]] && grep -a -q "$PYXIS_VERSION" "$plugin"; then
        log "Pyxis ${PYXIS_VERSION} is already installed"
    else
        log "Building Pyxis ${PYXIS_VERSION} against the installed Slurm ${SLURM_VERSION} headers"
        rm -rf "$BUILD_ROOT/pyxis"; install -d "$BUILD_ROOT/pyxis"
        curl --fail --location --retry 3 \
            "https://github.com/NVIDIA/pyxis/archive/refs/tags/v${PYXIS_VERSION}.tar.gz" \
            -o "$BUILD_ROOT/pyxis/pyxis.tar.gz"
        tar -xzf "$BUILD_ROOT/pyxis/pyxis.tar.gz" -C "$BUILD_ROOT/pyxis"
        make -C "$BUILD_ROOT/pyxis/pyxis-${PYXIS_VERSION}" -j"$(nproc)"
        make -C "$BUILD_ROOT/pyxis/pyxis-${PYXIS_VERSION}" install
    fi
    install -d -m 0755 /etc/slurm/plugstack.conf.d
    printf '%s\n' 'include /etc/slurm/plugstack.conf.d/*' > /etc/slurm/plugstack.conf
    ln -sfn /usr/local/share/pyxis/pyxis.conf /etc/slurm/plugstack.conf.d/pyxis.conf
}

install_slurm
install_enroot
install_pyxis

probe_script=$(cat <<'PROBE_EOF'
set -Eeuo pipefail

# Prefer Slurm's own hardware discovery when it is already installed.
if command -v slurmd >/dev/null 2>&1; then
    detected=$(slurmd -C 2>/dev/null | awk '/^NodeName=/{print; exit}')
    if [[ -n $detected ]]; then
        cpus=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^CPUs=/) {sub(/^CPUs=/,"",$i); print $i; exit}}' <<< "$detected")
        memory=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^RealMemory=/) {sub(/^RealMemory=/,"",$i); print $i; exit}}' <<< "$detected")
        gres=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^Gres=/) {sub(/^Gres=/,"",$i); print $i; exit}}' <<< "$detected")
        if [[ -n $cpus && -n $memory ]]; then
            printf '%s\t%s\t%s\n' "$cpus" "$memory" "${gres:-}"
            exit 0
        fi
    fi
fi

cpus=$(nproc --all)
# Reserve 5% for the OS when Slurm is not available to report RealMemory.
memory=$(awk '/^MemTotal:/ {printf "%d", ($2 / 1024) * 0.95; exit}' /proc/meminfo)
gres=""
if command -v nvidia-smi >/dev/null 2>&1; then
    declare -A gpu_counts=()
    while IFS= read -r gpu_name; do
        [[ -n $gpu_name ]] || continue
        gpu_type=$(printf '%s' "$gpu_name" | tr '[:upper:] ' '[:lower:]_' | sed -E 's/[^a-z0-9_.-]+/_/g; s/^_+|_+$//g')
        ((gpu_counts["$gpu_type"] += 1)) || true
    done < <(nvidia-smi --query-gpu=name --format=csv,noheader,nounits)
    for gpu_type in "${!gpu_counts[@]}"; do
        [[ -z $gres ]] || gres+=","
        gres+="gpu:${gpu_type}:${gpu_counts[$gpu_type]}"
    done
fi
printf '%s\t%s\t%s\n' "$cpus" "$memory" "$gres"
PROBE_EOF
)

node_config_lines=()
has_any_gpu=0
if ((is_controller)); then
    log "Discovering compute-node CPU, memory, and all GPUs"
    local_short=$(hostname -s)
    local_fqdn=$(hostname -f 2>/dev/null || hostname -s)
    for node in "${node_array[@]}"; do
        if ((manual_values == 3)); then
            detected_cpus=$CPUS_PER_NODE
            detected_memory=$REAL_MEMORY_MB
            detected_gres=""
            if ((GPUS_PER_NODE > 0)); then
                detected_gres="gpu:b200:${GPUS_PER_NODE}"
            fi
        elif [[ $node == "$local_short" || $node == "$local_fqdn" ]]; then
            probe_output=$(bash -c "$probe_script") || die "Hardware discovery failed on local node $node"
            IFS=$'\t' read -r detected_cpus detected_memory detected_gres <<< "$probe_output"
        else
            ssh_command=(ssh -o ConnectTimeout=15 "$node" bash -s)
            if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
                ssh_command=(sudo -H -u "$SUDO_USER" ssh -o ConnectTimeout=15 "$node" bash -s)
            fi
            if ! probe_output=$(printf '%s\n' "$probe_script" | "${ssh_command[@]}"); then
                die "Could not probe $node over SSH. Configure key-based SSH, or rerun with all three manual resource options."
            fi
            IFS=$'\t' read -r detected_cpus detected_memory detected_gres <<< "$probe_output"
        fi

        [[ $detected_cpus =~ ^[1-9][0-9]*$ ]] || die "Invalid detected CPU count from $node: $detected_cpus"
        [[ $detected_memory =~ ^[1-9][0-9]*$ ]] || die "Invalid detected memory from $node: $detected_memory"
        node_line="NodeName=${node} CPUs=${detected_cpus} RealMemory=${detected_memory}"
        if [[ -n $detected_gres && $detected_gres != '(null)' ]]; then
            [[ $detected_gres =~ ^gpu:[A-Za-z0-9_.-]+:[1-9][0-9]*(,gpu:[A-Za-z0-9_.-]+:[1-9][0-9]*)*$ ]] || \
                die "Invalid detected GRES from $node: $detected_gres"
            node_line+=" Gres=${detected_gres}"
            has_any_gpu=1
        fi
        node_line+=" State=UNKNOWN"
        node_config_lines+=("$node_line")
        log "$node_line"
    done
fi

log "Configuring MUNGE authentication"
install -d -o munge -g munge -m 0700 /etc/munge
if [[ -n $MUNGE_KEY_SOURCE ]]; then
    install -o munge -g munge -m 0400 "$MUNGE_KEY_SOURCE" /etc/munge/munge.key
elif [[ ! -s /etc/munge/munge.key ]]; then
    ((is_controller)) || die "Refusing to generate a different MUNGE key on a compute node"
    dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 status=none
    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key
fi
systemctl enable --now munge
munge -n | unmunge >/dev/null || die "Local MUNGE authentication test failed"

install -d -m 0755 /etc/slurm
if [[ -n $CLUSTER_BUNDLE ]]; then
    install -m 0644 "$bundle_dir/slurm.conf" /etc/slurm/slurm.conf
    [[ ! -f $bundle_dir/gres.conf ]] || install -m 0644 "$bundle_dir/gres.conf" /etc/slurm/gres.conf
    [[ ! -f $bundle_dir/cgroup.conf ]] || install -m 0644 "$bundle_dir/cgroup.conf" /etc/slurm/cgroup.conf
elif ((is_controller)); then
    log "Writing Slurm configuration"
    cat > /etc/slurm/slurm.conf <<EOF
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CONTROLLER}
SlurmctldParameters=enable_configless
AuthType=auth/munge
CredType=cred/munge
MpiDefault=none
ProctrackType=proctrack/cgroup
ReturnToService=2
SlurmctldPidFile=/run/slurmctld.pid
SlurmctldPort=6817
SlurmdPidFile=/run/slurmd.pid
SlurmdPort=6818
SlurmdSpoolDir=/var/spool/slurmd
SlurmUser=slurm
StateSaveLocation=/var/spool/slurmctld
SwitchType=switch/none
TaskPlugin=task/affinity,task/cgroup
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
GresTypes=gpu
EOF
    if [[ -n $EXTERNAL_SLURMDBD ]]; then
        [[ $EXTERNAL_SLURMDBD =~ $safe_name_re ]] || die "Unsafe SlurmDBD host"
        cat >> /etc/slurm/slurm.conf <<EOF
AccountingStorageExternalHost=${EXTERNAL_SLURMDBD}
EOF
    fi
    for node_line in "${node_config_lines[@]}"; do
        printf '%s\n' "$node_line" >> /etc/slurm/slurm.conf
    done
    printf 'PartitionName=gpu Nodes=%s Default=YES MaxTime=INFINITE State=UP\n' \
        "$COMPUTE_NODES" >> /etc/slurm/slurm.conf

    cat > /etc/slurm/cgroup.conf <<'EOF'
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
EOF
    if ((has_any_gpu)); then
        cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvidia
EOF
    else
        : > /etc/slurm/gres.conf
    fi
fi

[[ -f /etc/slurm/cgroup.conf ]] || cat > /etc/slurm/cgroup.conf <<'EOF'
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
EOF
[[ -f /etc/slurm/gres.conf ]] || : > /etc/slurm/gres.conf

getent passwd slurm >/dev/null || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin slurm
install -d -o slurm -g slurm -m 0755 /var/log/slurm /var/spool/slurmctld
install -d -o root -g root -m 0755 /var/spool/slurmd
chown root:root /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/gres.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/gres.conf

if ((is_controller)); then
    systemctl enable --now slurmctld
fi
if ((is_compute)); then
    log "Detected local compute resources"
    slurmd -C | sed -n '1p'
    if ! slurmd -G >/dev/null; then
        die "Slurm rejected the GPU configuration. Compare 'slurmd -C' and 'slurmd -G' with /etc/slurm/slurm.conf and /etc/slurm/gres.conf."
    fi
    systemctl enable --now slurmd
fi

if ((is_controller)); then
    bundle="/root/${CLUSTER_NAME}-slurm-bootstrap.tar.gz"
    bundle_stage=$(mktemp -d)
    install -m 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/gres.conf "$bundle_stage/"
    install -m 0400 /etc/munge/munge.key "$bundle_stage/munge.key"
    umask 077
    tar -czf "$bundle" -C "$bundle_stage" .
    chmod 0600 "$bundle"
    rm -rf "$bundle_stage"
fi

log "Validating installation"
scontrol --version
enroot version
test -f /usr/local/lib/slurm/spank_pyxis.so || die "Pyxis plugin is missing"
systemctl --no-pager --full status munge | sed -n '1,5p'
((is_controller == 0)) || systemctl --no-pager --full status slurmctld | sed -n '1,8p'
((is_compute == 0)) || systemctl --no-pager --full status slurmd | sed -n '1,8p'

if ((is_compute)) && command -v nvidia-smi >/dev/null 2>&1; then
    detected_gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    log "NVIDIA driver sees ${detected_gpus} GPU(s)"
elif ((is_compute)); then
    warn "nvidia-smi is unavailable. Install/verify the NVIDIA driver before GPU jobs."
fi
command -v nvidia-container-cli >/dev/null 2>&1 || \
    warn "libnvidia-container-tools is not installed; Enroot containers will not expose GPUs until it is installed."

printf '\nInstallation complete.\n'
if ((is_controller)); then
    printf 'Secure bundle for compute nodes: %s\n' "$bundle"
    printf 'Copy it securely to each compute node and run this script with --role compute --cluster-bundle FILE.\n'
fi
if ((is_compute)); then
    printf 'After the controller is running, test with:\n'
    printf '  sinfo\n'
    printf '  srun -N1 nvidia-smi\n'
    printf '  srun -N1 --container-image=ubuntu:24.04 cat /etc/os-release\n'
fi
printf 'Firewall requirements: TCP 6817 to the controller; TCP 6818 to compute nodes.\n'
printf 'Keep DNS, UID/GID identity, and time synchronized across the cluster.\n'
