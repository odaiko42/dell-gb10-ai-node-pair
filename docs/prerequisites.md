# Prérequis

🌐 **Langue / Language:** Français (actuel) · [English](en/prerequisites.md)

## Matériel

- 2 × nœuds GB10 (ou équivalent NVIDIA Grace Blackwell, mémoire unifiée), 128 Go chacun.
- Carte réseau ConnectX-7 (ou équivalent 200 GbE / InfiniBand) sur chaque nœud, avec un câble
  compatible validé par le constructeur (DAC/AOC, format QSFP, longueur et firmware corrects —
  ne pas choisir un câble uniquement parce que le connecteur semble entrer).
- Un réseau de management existant (LAN) pour l'administration, indépendant de la liaison CX7.

## Vérifications avant câblage

« GB10 128 Go » seul ne suffit pas à garantir la compatibilité logicielle : GB10 est le processeur,
les produits partenaires peuvent différer. Avant de suivre ce guide, vérifier sur vos deux machines :

```bash
hostnamectl
uname -m
cat /etc/os-release
nvidia-smi
nvcc --version
ip -br link
ip -br addr
ip route
lspci -nn
ibdev2netdev
rdma link show
free -h
df -h
```

Si `nvcc`, `ibdev2netdev` ou `rdma` sont absents, noter leur absence et installer les paquets
correspondants après vérification de version — ne pas installer un driver générique par-dessus
l'image constructeur sans procédure compatible.

## Logiciel

- OS Linux (Ubuntu/Debian ou équivalent constructeur), driver NVIDIA et CUDA correspondant à
  l'architecture Blackwell (`sm_121`/`sm_121a`).
- Un environnement conteneurisé reproductible plutôt que des paquets installés en système : les
  scripts de ce dépôt utilisent une image officielle NVIDIA (`nvcr.io/nvidia/pytorch:...`) identique
  sur les deux nœuds, avec les outils de build déjà présents (cmake, gcc, nvcc) pour compiler
  [llama.cpp](https://github.com/ggml-org/llama.cpp) avec support CUDA + backend RPC
  (`-DGGML_CUDA=ON -DGGML_RPC=ON`).
- `rsync`/`scp` ou équivalent pour synchroniser le binaire compilé entre les deux nœuds (même image,
  pas de recompilation nécessaire côté second nœud).
- `docker` avec le runtime `nvidia` enregistré (`nvidia-ctk runtime configure --runtime=docker`).

## Compte dédié et accès

- Un compte de calcul dédié (pas de droits sudo nécessaires pour lancer les jobs), identique sur les
  deux nœuds.
- Une paire de clés SSH dédiée à la liaison inter-nœuds (voir [networking.md](networking.md#ssh)),
  jamais réutilisée pour d'autres accès.

## Contraintes strictes recommandées

Quel que soit l'environnement, il est recommandé de fixer des garde-fous avant toute intervention :

- Ne jamais modifier les paramètres de démarrage (GRUB) dans le cadre de ce guide.
- Ne jamais lancer de mise à jour système/driver/firmware sans décision explicite séparée, même si
  une commande de diagnostic le suggère.
- Si l'un des deux nœuds exécute déjà des charges de production, ne réaliser que des opérations de
  lecture/diagnostic dessus tant que la procédure n'a pas été validée sur un nœud non critique.
