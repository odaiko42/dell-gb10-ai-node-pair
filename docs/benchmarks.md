# Résultats de benchmark détaillés

🌐 **Langue / Language:** Français (actuel) · [English](en/benchmarks.md)

Toutes les mesures ci-dessous ont été produites avec les scripts de ce dépôt, sur une paire de
nœuds GB10 réels (adresses et noms anonymisés, voir [networking.md](networking.md)). Les valeurs
de débit/temps sont spécifiques au matériel, au modèle et à la charge du nœud partagé au moment du
test — elles illustrent une méthode de mesure reproductible plus qu'une garantie de performance.

## 1. Collective NCCL (`smoke_ddp.py` via `torchrun`, 2 nœuds)

| Métrique | Valeur |
|---|---|
| `all_reduce` | 3.0 (identique sur les deux rangs) |

Valide que la liaison CX7 et la configuration NCCL (interfaces, variables d'environnement) permettent
une collective inter-nœuds fonctionnelle, préalable à tout entraînement distribué.

## 2. Validation fonctionnelle du partitionnement (`test_model_split_rpc.sh`)

| Métrique | Valeur |
|---|---|
| Modèle | Qwen2.5-3B-Instruct, Q4_K_M (~2 Go) |
| VRAM locale | ~2.9 GiB |
| VRAM distante (RPC) | ~0.9 GiB |

Confirme que les tenseurs sont réellement répartis entre les deux nœuds (et non dupliqués), et que
le nœud distant répond correctement aux requêtes d'inférence.

## 3. Débit intermédiaire (`bench_model_split_rpc.sh`, `llama-bench`)

| Métrique | Valeur |
|---|---|
| Modèle | Qwen2.5-14B-Instruct, Q4_K_M (8.37 GiB) |
| Prompt processing | 1566.75 t/s |
| Génération | 20.35 t/s |
| VRAM locale | ~5.3 GiB |
| VRAM distante (RPC) | ~3.7 GiB |

## 4. Test à grande échelle (`bench_scale_model_split_rpc.sh`), modèle ~70B+

Ce test charge un modèle dont la taille approche la capacité utilisable combinée des deux nœuds, avec
répartition auto-adaptative (`-ts`) proportionnelle à la mémoire réellement disponible au moment du
test, et les garde-fous décrits dans [troubleshooting.md](troubleshooting.md) (re-check mémoire
périodique + arrêt préventif pendant le chargement).

| Métrique | Valeur |
|---|---|
| Modèle | Qwen2.5-72B-Instruct, Q4_K_M (~41 GiB, 12 fichiers) |
| Capacité combinée utilisable au moment du test | ~175.8 GiB (marge de sécurité 12 GiB/nœud) |
| Répartition (`-ts`) | proportionnelle à la mémoire libre de chaque nœud |
| Temps de chargement | 68.2 s |
| Volume transféré pendant le chargement | ~25.1 GiB (émis par le nœud local, reçus par le nœud distant) |
| Débit réseau pendant le chargement | 3.17 Gb/s (1.6 % du lien 200 Gb/s nominal) |
| VRAM locale après chargement | ~17.7 GiB |
| VRAM distante après chargement (processus RPC) | ~26.0 GiB |
| Débit prompt | 51.76 t/s |
| Débit génération | 4.55 t/s |
| Perturbation des charges existantes sur le nœud distant | Aucune (vérifié par comparaison VRAM avant/après des processus préexistants) |

**Observations :**
- Le débit réseau mesuré pendant le chargement est très en-deçà de la capacité nominale du lien :
  le facteur limitant est la lecture disque et la désérialisation des tenseurs côté CPU, pas la
  bande passante réseau.
- Le débit de génération est nettement inférieur à celui du modèle 14B (point 3), ce qui est attendu :
  chaque token généré traverse une fois de plus la liaison réseau pour les couches hébergées sur le
  nœud distant, et l'écart se creuse avec le nombre de couches distantes.
- Le script a effectué des re-vérifications mémoire périodiques pendant tout le chargement sans
  déclencher d'arrêt préventif, signe que la marge de sécurité appliquée (12 Gio) était suffisante
  dans les conditions du test.

## 5. Test à très grande échelle (`bench_scale_model_split_rpc.sh`), modèle ~140 Gio (FP16)

Ce test pousse la méthode du point 4 beaucoup plus loin : chargement d'un modèle non quantifié
(FP16) de ~136 GiB, en libérant temporairement les charges de production du nœud distant (arrêt
contrôlé de deux services + un conteneur, redémarrage garanti après le test) pour disposer d'assez
de mémoire combinée. Objectif : mesurer la capacité réelle du cluster proche de son plafond
théorique, et le compromis débit/taille qui en résulte.

| Métrique | Valeur |
|---|---|
| Modèle | Qwen2.5-72B-Instruct, FP16 (~135.9 GiB, 42 fichiers) |
| Capacité combinée utilisable au moment du test | ~189.5 GiB (marge de sécurité 16 GiB/nœud, charges de prod temporairement arrêtées côté distant) |
| Répartition (`-ts`) | proportionnelle à la mémoire libre de chaque nœud (102920,91159) |
| Temps de chargement | 284.05 s |
| Volume transféré pendant le chargement | 73.78 GiB (émis, local) / 73.77 GiB (reçu, distant) |
| Débit réseau pendant le chargement | 2.23 Gb/s (1.1 % du lien 200 Gb/s nominal) |
| VRAM locale après chargement | ~64.1 GiB |
| VRAM distante après chargement (processus RPC) | ~71.8 GiB |
| Débit prompt | 24.11 t/s (16 tokens) |
| Débit génération | 1.65 t/s (67 tokens) |
| Perturbation des charges de production existantes sur le nœud distant | Aucune (VRAM du processus de production préexistant inchangée ; services redémarrés et vérifiés sains immédiatement après le test) |

**Observations :**
- Avec un modèle deux fois plus volumineux que le test Q4_K_M du point 4, le temps de chargement
  augmente proportionnellement plus que la taille (284 s vs 68 s pour ~3.3× plus de données), signe
  que la désérialisation CPU et/ou la pression mémoire deviennent le facteur limitant à cette échelle.
- Le débit de génération (1.65 t/s) illustre le compromis direct entre taille de modèle non quantifié
  et latence d'inférence répartie par RPC : chaque couche distante ajoute une traversée réseau par
  token, et le volume de données par couche double par rapport à une quantification Q4_K_M.
- Ce test nécessite de libérer temporairement de la mémoire côté nœud distant (arrêt contrôlé de
  charges de production non liées au test, redémarrage systématique après coup, avec vérification
  de santé complète : absence d'OOM, VRAM des processus de production inchangée, endpoints HTTP de
  production répondant normalement). Il illustre la capacité combinée maximale mesurable du
  cluster, pas un mode de fonctionnement courant.

## 6. Validation réseau/SSH/RDMA (`test_dual_gb10.sh`)

| Métrique | Valeur |
|---|---|
| Résultat | 9 PASS / 0 FAIL / 1 SKIP |
| Test ignoré | `iperf3` non installé sur l'un des deux nœuds au moment de la mesure |
