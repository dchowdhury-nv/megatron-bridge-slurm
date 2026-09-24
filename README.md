# Slurm + Enroot + Pyxis bootstrap

This installer targets Ubuntu 24.04 and installs these upstream versions:

- Slurm 24.11.7 (built as SchedMD Debian packages)
- Enroot 4.1.2
- Pyxis 0.20.0 (compiled against the installed Slurm headers)

The `-101099-cm11.0` strings in the source table are NVIDIA Base Command
Manager package revisions. They are not available from the upstream projects;
this script installs the same upstream component versions without that vendor
revision.

## 1. Run on the bastion/controller

```bash
chmod +x setup-slurm-enroot-pyxis.sh
sudo ./setup-slurm-enroot-pyxis.sh
```

Choose `bastion/controller`. The installer probes each compute node over SSH.
It uses `slurmd -C` when available, otherwise `nproc`, `/proc/meminfo`, and
`nvidia-smi`. Every detected GPU is included in the node's Slurm `Gres` value.
Configure SSH access from the bastion first. Fully manual CPU, memory, and GPU
count options remain available for isolated nodes.

The controller creates a mode-0600 bundle under `/root`, for example:

```text
/root/exp-blr-slurm-bootstrap.tar.gz
```

It contains `slurm.conf` and the secret MUNGE key. Transfer it securely and
remove extra copies after provisioning.

## 2. Run on every compute node

```bash
sudo ./setup-slurm-enroot-pyxis.sh \
  --role compute \
  --cluster-bundle /root/exp-blr-slurm-bootstrap.tar.gz
```

## 3. Test from the bastion

```bash
sinfo
srun -N1 hostname
srun -N1 nvidia-smi
srun -N1 --container-image=ubuntu:24.04 cat /etc/os-release
```

All nodes need consistent forward/reverse name resolution, synchronized time,
and matching user/group IDs. Permit TCP 6817 to the controller and TCP 6818 to
compute nodes. Enroot also needs `libnvidia-container-tools` for GPU injection;
the script warns if the DGX image does not already provide it.

## Multiple clusters

The bundle makes any number of nodes members of one Slurm cluster. Independent
Slurm clusters need a shared SlurmDBD/accounting database (and usually a Slurm
federation) to use cross-cluster commands such as `squeue -M all`. If that
service already exists, pass `--external-slurmdbd HOST` when configuring each
controller. This script deliberately does not deploy a database or silently
share a MUNGE key between independent security domains.

## Uninstall

Use the matching uninstaller on every controller and compute node:

```bash
sudo ./uninstall-slurm-enroot-pyxis.sh
```

It requires typing `DELETE`, creates a mode-0600 backup under `/root`, stops the
services, purges the installed Slurm/Enroot/MUNGE packages, removes Pyxis, and
deletes system configuration and service state. It deliberately retains build
tools, shared dependencies, and users' Enroot images. Use `--keep-data` to
retain `/etc/slurm`, `/etc/munge`, and Slurm state, or `--yes` for automation.

## NeMo pretraining job

`nemo-pretrain.sbatch` launches `pretrain.py` in
`nvcr.io/nvidia/nemo:26.06` through Pyxis. Submit it from a shared directory
that is available at the same path on every compute node:

```bash
sbatch nemo-pretrain.sbatch
```

The default requests two GPUs, matching the detected example node. Override
the resource directives at submission time for other allocations:

```bash
sbatch --nodes=4 --gpus-per-node=8 nemo-pretrain.sbatch
```

The job uses Pyxis `--container-remap-root`, which presents the unprivileged
submitting user as UID/GID `0:0` inside the container. It mounts only the source
directory and `$PWD/.cache`; the latter appears as `/root/.cache`. Enroot,
Hugging Face, Torch, Triton, NeMo, Megatron, uv/pip, CUDA, temporary, and W&B
caches are kept below that mount. The host home directory is not mounted.
Each job starts in `/root/.cache/runs/<job-id>` and invokes `pretrain.py` by its
absolute mounted path. NeMo's default relative `nemo_experiments` directory is
therefore stored at `$PWD/.cache/runs/<job-id>/nemo_experiments`, rather than in
the source tree.
