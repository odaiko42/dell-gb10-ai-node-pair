import os
from datetime import timedelta
import torch
import torch.distributed as dist

local_rank = int(os.environ['LOCAL_RANK'])
torch.cuda.set_device(local_rank)
dist.init_process_group(backend='nccl', timeout=timedelta(seconds=120))
try:
    rank = dist.get_rank()
    size = dist.get_world_size()
    x = torch.tensor([float(rank + 1)], device=f'cuda:{local_rank}')
    dist.all_reduce(x, op=dist.ReduceOp.SUM)
    torch.cuda.synchronize()
    expected = float(size * (size + 1) // 2)
    if x.item() != expected:
        raise RuntimeError(f'all_reduce incorrect: {x.item()} expected {expected}')
    print(f'rank={rank} world_size={size} all_reduce={x.item()}', flush=True)
finally:
    dist.destroy_process_group()
