# Dépannage

🌐 **Langue / Language:** Français (actuel) · [English](en/troubleshooting.md)

## Mémoire unifiée Grace Blackwell : piège de diagnostic

- `nvidia-smi --query-gpu=memory.total,memory.used,memory.free` peut renvoyer des champs vides
  (`N/A`) selon la version de driver sur cette architecture. S'appuyer à la place sur le log de
  l'outil d'inférence utilisé (ex. `ggml_cuda_init` de llama.cpp affiche la VRAM totale réelle).
- `nvidia-smi --query-compute-apps` ne reflète que la mémoire attribuée aux processus CUDA : sur un
  nœud qui exécute aussi des charges non-GPU, la pression mémoire réelle peut être largement
  sous-estimée. Toujours croiser avec `MemAvailable` (`/proc/meminfo`, mémoire système incluant le
  cache réclamable) et l'usage du swap avant de considérer qu'une marge est suffisante :

  ```bash
  awk '/MemAvailable/{print int($2/1024)" MiB"}' /proc/meminfo
  awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)" MiB swap utilisé"}' /proc/meminfo
  ```

- **Un contrôle ponctuel avant une opération longue (chargement d'un gros modèle, plusieurs
  minutes) ne suffit pas sur un nœud dont la charge varie dans le temps** : la mémoire disponible
  peut se dégrader significativement en cours d'opération. Prévoir une re-vérification périodique
  pendant l'opération, avec un mécanisme d'arrêt automatique si un plancher critique est franchi,
  plutôt qu'un seul check initial (voir
  [scripts/bench_scale_model_split_rpc.sh](../scripts/bench_scale_model_split_rpc.sh) pour un
  exemple d'implémentation : re-check toutes les N secondes + abort préventif + nettoyage des
  conteneurs avant qu'un OOM réel ne survienne).

## Locale système et scripts mélangeant `awk` et `printf`

Si le shell est dans une locale à virgule décimale (ex. `fr_FR`), un nombre flottant produit par
`awk` (point décimal) peut faire échouer `printf "%f"` (`nombre non valable`). Ajouter
`export LC_ALL=C` en tête de script résout ce problème sans affecter le reste de l'exécution.

## Échappement `$` dans une commande `awk` exécutée à distance via SSH

Lorsqu'une commande `awk` contenant des références de champ (`$1`, `$2`) est passée à travers une
fonction shell qui l'enveloppe dans `ssh ... "$cmd"`, un seul niveau d'échappement (`\$2`) suffit à
l'endroit où le shell local interprèterait sinon prématurément le `$`. Un excès d'échappement
(`\\\\\\$2`) provoque une erreur `awk: backslash not last character on line`.

## Mot de passe sudo inattendu sur un nœud normalement configuré sans mot de passe

Si un nœud configuré pour `sudo` sans mot de passe se met soudainement à en redemander un (session
expirée, politique modifiée, etc.), ne jamais saisir le mot de passe dans un terminal piloté par un
outil d'automatisation. Utiliser une commande équivalente sans `sudo` si le compte est déjà membre
du groupe nécessaire (ex. `docker`), ou escalader vers un humain.

## Interface réseau non détectée / nom différent entre les deux nœuds

Les noms d'interfaces (`enp1s0f0np0`, etc.) peuvent différer d'un nœud à l'autre. Les scripts de ce
dépôt détectent dynamiquement leur propre rôle (A/B) à partir des IP de management locales plutôt
que de supposer un nom d'interface fixe — voir le motif `detectRole`/`role` répété dans chacun des
scripts sous [scripts/](../scripts).

## `llama-bench` / `llama-server` : erreur `libcuda.so.1: cannot open shared object file`

Le conteneur Docker doit être lancé avec `--gpus all` (et pas seulement un montage de volume) pour
exposer le runtime CUDA, y compris pour un simple `--help`.

## Dépôts GGUF découpés en plusieurs fichiers

Les dépôts GGUF publiés par les éditeurs de modèles sont fréquemment découpés en plusieurs fichiers
(`modele-q4_k_m-00001-of-00003.gguf`, etc.), même pour des tailles modestes. Vérifier la liste exacte
des fichiers via l'API du dépôt avant de télécharger en devinant une URL. Les outils d'inférence
basés sur `llama.cpp` chargent nativement le modèle complet à partir du chemin du premier fichier,
sans fusion manuelle requise.
