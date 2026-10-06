# Réseau

🌐 **Langue / Language:** Français (actuel) · [English](en/networking.md)

## Plan d'adressage proposé

| Plan | Node-A | Node-B | Usage |
|---|---|---|---|
| Management | `10.0.0.11` (exemple) | `10.0.0.12` (exemple) | Administration, SSH, accès LAN/Internet contrôlé |
| CX7 logique 1 | `10.10.0.1/30` | `10.10.0.2/30` | Calcul/transport inter-nœuds |
| CX7 logique 2 | `10.10.1.1/30` | `10.10.1.2/30` | Second chemin logique de la même liaison physique |

Ces adresses sont une **proposition**, pas des valeurs imposées par le constructeur. Vérifier
qu'elles ne chevauchent ni le LAN, ni un VPN, ni les réseaux Docker/Kubernetes existants. En cas de
chevauchement, choisir d'autres sous-réseaux et les remplacer partout (y compris dans les variables
d'environnement des scripts, voir [../scripts](../scripts)).

Aucune passerelle, aucun DNS et aucune route par défaut sur les interfaces CX7. Le management
conserve sa route par défaut existante. Pas de bridge entre CX7 et LAN.

## Configuration Netplan (exemple)

Les noms d'interfaces réels (`ip -br link`, `ibdev2netdev`) sont spécifiques à chaque machine — ne
jamais appliquer un fichier tel quel sans les adapter. Voir
[config/netplan/60-cx7.yaml.example](../config/netplan/60-cx7.yaml.example).

Procédure recommandée (à exécuter depuis un accès local/management, jamais uniquement via la
liaison en cours de configuration) :

```bash
# Sauvegarde avant toute modification
sudo install -d -m 700 /root/cluster-netplan-backup
sudo cp -a /etc/netplan/. /root/cluster-netplan-backup/

# Après avoir adapté le fichier (noms d'interfaces + IP réelles)
sudo chmod 600 /etc/netplan/60-cx7.yaml
sudo netplan generate
sudo netplan try --timeout 120   # confirme automatiquement le retour arrière si non validé
```

Vérifications après application, sur chaque nœud :

```bash
ip route get <ip_cx7_pair_lien1>
ping -c 5 <ip_cx7_pair_lien1>
```

Tester aussi la persistance après un redémarrage contrôlé.

### Retour arrière

Si le nouveau fichier est la seule modification : le déplacer hors de `/etc/netplan`, relancer
`netplan generate` puis appliquer depuis un accès local/management sûr. Ne pas supprimer tout le
contenu de `/etc/netplan`.

## SSH

Utiliser une clé dédiée à la liaison inter-nœuds, jamais réutilisée ailleurs :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_cluster
ssh-copy-id -i ~/.ssh/id_ed25519_cluster.pub <user>@<ip_cx7_pair>
```

- Vérifier l'empreinte de la clé hôte distante via un canal fiable avant d'accepter la connexion.
- Ne jamais copier une clé privée entre machines.
- Ne jamais utiliser `StrictHostKeyChecking=no` comme solution normale.
- Restreindre `authorized_keys` par IP source si possible.

Exemple de configuration client : [config/ssh/config.example](../config/ssh/config.example).

## Matrice de ports (exemple)

| Port/protocole | Service | Portée recommandée |
|---|---|---|
| TCP 22 | SSH | Management ; CX7 entre les deux IP des nœuds si l'outil de lancement l'utilise |
| TCP dynamiques | NCCL bootstrap/sockets, MPI | Interfaces CX7 uniquement, peer exact |
| UDP 4791 | RoCEv2 | Entre interfaces CX7 des deux nœuds si transport RoCE actif |
| TCP (port RPC choisi) | Backend RPC llama.cpp | CX7 privé uniquement — **jamais** exposé sur le LAN ni Internet (protocole non authentifié/non chiffré par conception) |
| TCP 5201 | iperf3 (diagnostic ponctuel) | CX7, temporaire, fermer après mesure |

Ne pas ouvrir de ports « au cas où ». Si un moteur de parallélisme supplémentaire (Ray, etc.) est
introduit plus tard, documenter sa propre matrice de ports avant de l'activer.

## Validation du lien physique

```bash
# Côté B (temporaire)
iperf3 -s -B <ip_cx7_B>

# Côté A
iperf3 -c <ip_cx7_B> -B <ip_cx7_A> -P 4 -t 30
iperf3 -c <ip_cx7_B> -B <ip_cx7_A> -P 4 -t 30 -R
```

Le débit nominal du lien n'est pas une garantie de débit applicatif ; `iperf3` ne valide que le
transport TCP, pas le fonctionnement de RoCE/NCCL (voir [mpi-nccl.md](mpi-nccl.md)).

Le script [scripts/test_dual_gb10.sh](../scripts/test_dual_gb10.sh) automatise l'ensemble de ces
vérifications (ping management, interfaces CX7, SSH par clé, RDMA, GPU local/distant, et
optionnellement iperf3 via `--with-iperf3`).
