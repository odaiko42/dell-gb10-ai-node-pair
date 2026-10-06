# MPI / NCCL

## Objectif

Valider qu'une collective NCCL minimale (`all_reduce`) fonctionne correctement entre les deux nœuds
via la liaison CX7, avant de tenter un entraînement distribué réel. Ce test ne mesure pas la
qualité d'un modèle ni la tenue en charge mémoire — uniquement la communication collective.

## Sélection de l'interface réseau pour NCCL

À adapter sur chaque nœud selon les noms d'interfaces réels (`ip -br link`, `ibdev2netdev`,
`rdma link show`) :

```bash
export NCCL_SOCKET_IFNAME='=<iface_cx7_1>,<iface_cx7_2>'
export NCCL_SOCKET_FAMILY=AF_INET
export NCCL_DEBUG=INFO
export NCCL_IB_HCA='=<rdma_dev_1>:1,<rdma_dev_2>:1'
```

Ne pas copier les noms observés sur une autre machine. Tester d'abord la sélection automatique
avant de forcer un GID index. `NCCL_IB_DISABLE=1` sert à diagnostiquer un repli sur socket, pas à
valider que RoCE fonctionne.

## Vérification de l'environnement PyTorch/CUDA

```bash
python -c 'import torch; print(torch.__version__); print(torch.cuda.is_available()); \
print(torch.cuda.get_device_name(0)); print(torch.cuda.nccl.version())'
```

## Smoke test deux nœuds

Script : [scripts/smoke_ddp.py](../scripts/smoke_ddp.py) — identique sur les deux machines.

```bash
# Node-A (rank 0)
torchrun --nnodes=2 --nproc-per-node=1 --node-rank=0 \
  --master-addr=<ip_cx7_A> --master-port=29500 smoke_ddp.py

# Node-B (rank 1)
torchrun --nnodes=2 --nproc-per-node=1 --node-rank=1 \
  --master-addr=<ip_cx7_A> --master-port=29500 smoke_ddp.py
```

Attendu : `world_size=2` et `all_reduce=3.0` sur chaque rang (somme de `rank+1` pour les deux rangs).
Le premier processus lancé attend le second — démarrer B avant expiration du timeout.

Test négatif recommandé : arrêter B avant la collective et vérifier que A échoue de façon bornée
(timeout traduit en erreur, ressources libérées), plutôt que de rester bloqué indéfiniment.

## Au-delà du smoke test

La suite officielle [nccl-tests](https://github.com/NVIDIA/nccl-tests) (`all_reduce`, `all_gather`,
etc.) permet de mesurer un vrai débit (`busbw`) en augmentant progressivement la taille des buffers.
`busbw` des collectives et le débit Ethernet brut (Gb/s) ne sont pas des métriques interchangeables.

## Résultat mesuré sur ce cluster (2 nœuds, interconnexion CX7)

| Test | Résultat |
|---|---|
| `torchrun` 2 nœuds, `all_reduce` | `rank=0 world_size=2 all_reduce=3.0` et `rank=1 world_size=2 all_reduce=3.0` — collective validée de bout en bout |
