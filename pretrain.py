import os
# ---> MEMORY OPTIMIZATION 4: NCCL Stream Management
# Prevents PyTorch's NCCL integration from keeping memory buffers alive unnecessarily
# across CUDA streams, which is a major source of hidden OOMs in Megatron.
os.environ["TORCH_NCCL_AVOID_RECORD_STREAMS"] = "1"
os.environ["NCCL_NVLS_ENABLE"] = "0"

import torch
from megatron.bridge import AutoBridge
from megatron.bridge.recipes.common import _pretrain_common
from megatron.bridge.training.pretrain import pretrain
from megatron.bridge.training.gpt_step import forward_step

def qwen3_5_4b_pretrain_config():
    """
    Returns a pre-training config for a Qwen 4B architecture.
    Uses Megatron-Bridge to convert HuggingFace configs dynamically into Megatron format.
    """
    # Load the common pretraining configurations
    cfg = _pretrain_common()
    
    # Megatron-Bridge reads the HF config.json to construct the model.
    hf_model_id = "Qwen/Qwen3.5-4B" 
    
    # 1. Model Configuration
    cfg.model = AutoBridge.from_hf_pretrained(hf_model_id).to_megatron_provider(load_weights=False)
    
    # Override the massive default sequence length to a standard pretraining size
    cfg.model.seq_length = 4096
    cfg.model.max_position_embeddings = 4096
    
    # 2. Parallelism Settings
    cfg.model.tensor_model_parallel_size = 1
    cfg.model.pipeline_model_parallel_size = 1
    
    # 3. Tokenizer Configuration
    cfg.tokenizer.tokenizer_model = hf_model_id
    cfg.tokenizer.trust_remote_code = True
    
    # 4. Dataset Configuration
    cfg.dataset.blend = None
    cfg.dataset.num_workers = 0  
    cfg.dataset.seq_length = 4096
    
    # 5. Training Loop Configuration
    # Performance fix: MBS=2 with GBS=16 and 8 GPUs equals exactly 1 micro-batch 
    # per step. This naturally bypasses gradient accumulation memory leaks, meaning 
    # we do not need recomputation or disabled overlaps on H100s.
    cfg.train.micro_batch_size = 1  
    cfg.train.global_batch_size = 8  
    cfg.train.train_iters = 10000
    cfg.train.eval_iters = 50
    cfg.train.eval_interval = 500
    cfg.train.save_interval = 1000
    
    # Output directories
    cfg.train.tensorboard_dir = "./tensorboard_qwen"
    cfg.train.save_dir = "./checkpoints_qwen"
    
    # Precision
    cfg.mixed_precision = "bf16_mixed"

    # Distributed Optimizer (ZeRO-1) - Keeps memory highly optimized
    if not hasattr(cfg, 'optim'):
        from megatron.bridge.training.config import OptimizerConfig
        cfg.optim = OptimizerConfig()
    cfg.optim.use_distributed_optimizer = True

    return cfg

if __name__ == "__main__":
    config = qwen3_5_4b_pretrain_config()
    pretrain(config, forward_step)