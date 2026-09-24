#!/bin/bash
#SBATCH --job-name=nemo-pretrain
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=2
#SBATCH --cpus-per-task=16
#SBATCH --mem=0
#SBATCH --time=24:00:00
#SBATCH --output=logs/slurm-%x-%j.out
#SBATCH --error=logs/slurm-%x-%j.err

# Submit from the directory containing pretrain.py:
#   sbatch nemo-pretrain.sbatch
#
# Multi-node example (one torchrun launcher per node):
#   sbatch --nodes=4 --gpus-per-node=2 nemo-pretrain.sbatch
#
# On an eight-GPU node:
#   sbatch --gpus-per-node=8 nemo-pretrain.sbatch

set -Eeuo pipefail

# CONTAINER_IMAGE="nvcr.io/nvidia/nemo:26.06"
# For cached conatiner image
CONTAINER_IMAGE="../nemo-26-06.sqsh"
export SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
CACHE_DIR="${SUBMIT_DIR}/.cache"
RUN_DIR_HOST="${CACHE_DIR}/runs/${SLURM_JOB_ID}"
RUN_DIR_CONTAINER="/root/.cache/runs/${SLURM_JOB_ID}"

[[ -f "${SUBMIT_DIR}/pretrain.py" ]] || {
    echo "ERROR: ${SUBMIT_DIR}/pretrain.py does not exist." >&2
    echo "Submit this job from the directory containing pretrain.py." >&2
    exit 1
}

# Keep the host-side Enroot image cache in the submission directory. Inside
# the container this directory is mounted directly at /root/.cache.
export ENROOT_CACHE_PATH="${CACHE_DIR}/enroot"
mkdir -p "${ENROOT_CACHE_PATH}" "${RUN_DIR_HOST}"

mapfile -t ALLOCATED_HOSTS < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
(( ${#ALLOCATED_HOSTS[@]} > 0 )) || {
    echo "ERROR: Slurm returned an empty host list." >&2
    exit 1
}

export NNODES="${SLURM_NNODES}"
export MASTER_ADDR="${ALLOCATED_HOSTS[0]}"
# Derive a job-specific port to reduce collisions between jobs on the same hosts.
export MASTER_PORT="${MASTER_PORT:-$((20000 + SLURM_JOB_ID % 20000))}"

# Useful defaults for diagnosing distributed NCCL failures. Override at submit
# time if desired, for example: NCCL_DEBUG=INFO sbatch nemo-pretrain.sbatch
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export PYTHONUNBUFFERED=1

echo "====================================================="
echo "Starting Megatron-Bridge pretraining through Slurm"
echo "Job:        ${SLURM_JOB_ID}"
echo "Nodes:      ${NNODES} (${SLURM_JOB_NODELIST})"
echo "Master:     ${MASTER_ADDR}:${MASTER_PORT}"
echo "Container:  ${CONTAINER_IMAGE}"
echo "Source:     ${SUBMIT_DIR}"
echo "Cache mount:${CACHE_DIR} -> /root/.cache"
echo "Run dir:    ${RUN_DIR_HOST}"
echo "====================================================="

# Launch exactly one torchrun process on each allocated node. Each torchrun
# process then creates one worker per GPU visible inside its Pyxis container.
srun \
    --nodes="${NNODES}" \
    --ntasks="${NNODES}" \
    --ntasks-per-node=1 \
    --kill-on-bad-exit=1 \
    --container-image="${CONTAINER_IMAGE}" \
    --container-mounts="${SUBMIT_DIR}:${SUBMIT_DIR},${CACHE_DIR}:/root/.cache" \
    --container-workdir="${RUN_DIR_CONTAINER}" \
    --container-remap-root \
    --no-container-mount-home \
    bash -c '
        set -Eeuo pipefail

        # --container-remap-root is the Pyxis/Enroot equivalent of Docker
        # --user 0:0. It maps the submitting user to root inside the user
        # namespace without granting host root privileges.
        if [[ $(id -u) != 0 || $(id -g) != 0 ]]; then
            echo "ERROR: expected container UID:GID 0:0, got $(id -u):$(id -g)." >&2
            exit 1
        fi

        export HOME=/root
        export XDG_CACHE_HOME=/root/.cache
        export XDG_CONFIG_HOME=/root/.cache/config
        export XDG_DATA_HOME=/root/.cache/data
        export TMPDIR=/root/.cache/tmp
        export ENROOT_CACHE_PATH=/root/.cache/enroot
        export HF_HOME=/root/.cache/huggingface
        export HF_HUB_CACHE=/root/.cache/huggingface/hub
        export HF_DATASETS_CACHE=/root/.cache/huggingface/datasets
        export TRANSFORMERS_CACHE=/root/.cache/huggingface/transformers
        export TORCH_HOME=/root/.cache/torch
        export TORCH_EXTENSIONS_DIR=/root/.cache/torch-extensions
        export TRITON_CACHE_DIR=/root/.cache/triton
        export CUDA_CACHE_PATH=/root/.cache/cuda
        export NUMBA_CACHE_DIR=/root/.cache/numba
        export NEMO_HOME=/root/.cache/nemo
        export NEMO_DATASETS_CACHE=/root/.cache/nemo-datasets
        export MEGATRON_CACHE=/root/.cache/megatron
        export UV_CACHE_DIR=/root/.cache/uv
        export PIP_CACHE_DIR=/root/.cache/pip
        export MPLCONFIGDIR=/root/.cache/matplotlib
        export WANDB_DIR=/root/.cache/wandb
        export WANDB_CACHE_DIR=/root/.cache/wandb/cache
        export WANDB_CONFIG_DIR=/root/.cache/wandb/config
        export WANDB_DATA_DIR=/root/.cache/wandb/data
        export PYTHONPATH="${SUBMIT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

        mkdir -p \
            "${XDG_CONFIG_HOME}" \
            "${XDG_DATA_HOME}" \
            "${TMPDIR}" \
            "${HF_HUB_CACHE}" \
            "${HF_DATASETS_CACHE}" \
            "${TORCH_EXTENSIONS_DIR}" \
            "${TRITON_CACHE_DIR}" \
            "${WANDB_CACHE_DIR}" \
            "${WANDB_CONFIG_DIR}" \
            "${WANDB_DATA_DIR}"

        # Prefer the GPUs assigned to this Slurm task. NVML/nvidia-smi can show
        # physical GPUs beyond the allocation on some cluster configurations.
        if [[ -n ${CUDA_VISIBLE_DEVICES:-} && ${CUDA_VISIBLE_DEVICES} != NoDevFiles ]]; then
            IFS="," read -r -a VISIBLE_GPUS <<< "${CUDA_VISIBLE_DEVICES}"
            NPROC_PER_NODE=${#VISIBLE_GPUS[@]}
        elif [[ ${SLURM_GPUS_ON_NODE:-} =~ ^[0-9]+$ ]]; then
            NPROC_PER_NODE=${SLURM_GPUS_ON_NODE}
        elif [[ ${SLURM_GPUS_PER_NODE:-} =~ ^[0-9]+$ ]]; then
            NPROC_PER_NODE=${SLURM_GPUS_PER_NODE}
        else
            NPROC_PER_NODE=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
        fi

        if ((NPROC_PER_NODE < 1)); then
            echo "ERROR: No GPUs are visible on $(hostname)." >&2
            exit 1
        fi

        echo "Node $(hostname): rank=${SLURM_PROCID}/${NNODES}, GPUs=${NPROC_PER_NODE}"

        exec torchrun \
            --nproc_per_node="${NPROC_PER_NODE}" \
            --nnodes="${NNODES}" \
            --node_rank="${SLURM_PROCID}" \
            --master_addr="${MASTER_ADDR}" \
            --master_port="${MASTER_PORT}" \
            "${SUBMIT_DIR}/pretrain.py"
    '
