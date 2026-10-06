#!/usr/bin/env bash
# Test de comportement a grande echelle d'un modele reparti sur deux noeuds (backend RPC llama.cpp) :
# mesure le temps de chargement, le debit reseau reel sur le lien CX7 pendant ce chargement (et son taux
# de saturation par rapport au debit nominal du lien), puis le debit d'inference (prompt/generation).
#
# Contrairement a bench_model_split_rpc.sh, ce script est AUTO-ADAPTATIF : il mesure la memoire
# reellement disponible sur chaque noeud (utile si l'un des deux noeuds est une machine partagee dont
# la charge varie dans le temps), applique une marge de securite, refuse de demarrer si le modele
# depasse la capacite utilisable du moment, et repartit les couches (-ts/--tensor-split)
# proportionnellement a la capacite libre de chaque noeud plutot qu'un partage force 50/50 qui
# risquerait de saturer le noeud le plus charge.
#
# Usage : ./bench_scale_model_split_rpc.sh [chemin_modele.gguf] [marge_securite_mib] [n_gen] \
#              [plancher_critique_mib] [intervalle_check_s] [swap_alerte_mib]
#   [chemin_modele.gguf]   Optionnel. Si omis : mode diagnostic, affiche juste la capacite utilisable
#                          actuelle sur les deux noeuds et s'arrete (aucun conteneur demarre).
#                          Accepte un modele decoupe en plusieurs fichiers HuggingFace
#                          (ex: modele-q4_k_m-00001-of-00012.gguf) : donner le chemin de la 1ere partie,
#                          les autres parties du meme repertoire sont detectees et sommees automatiquement.
#   [marge_securite_mib]   Marge de memoire a laisser libre sur CHAQUE noeud, en MiB (defaut: 8192 = 8 Go).
#   [n_gen]                Nombre de tokens generes pour la mesure de debit finale (defaut: 128).
#   [plancher_critique_mib] Seuil absolu de MemAvailable (defaut: 6144 = 6 Go) : si l'UN ou l'AUTRE noeud
#                          passe sous ce seuil PENDANT le chargement, arret preventif immediat (le check
#                          initial seul ne suffit pas -- un noeud partage/volatil peut se degrader en
#                          quelques minutes ; voir docs/troubleshooting.md).
#   [intervalle_check_s]  Frequence de re-verification memoire pendant le chargement, en secondes
#                          (defaut: 15).
#   [swap_alerte_mib]     Hausse de swap distant depuis le debut du test qui declenche aussi un arret
#                          preventif, en MiB (defaut: 3072 = 3 Go).
#
# Configuration reseau/identite via variables d'environnement (voir defauts ci-dessous).
#
# Exemple (diagnostic, sans rien lancer) :
#   ./bench_scale_model_split_rpc.sh
# Exemple (test reel avec un modele proche de la capacite utilisable du moment) :
#   ./bench_scale_model_split_rpc.sh models/gros-modele-q4_k_m-00001-of-00012.gguf

set -euo pipefail
export LC_ALL=C   # evite les soucis de printf (virgule decimale locale) en melangeant awk/bash

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
llamaDir="$scriptDir/llama.cpp"
image="nvcr.io/nvidia/pytorch:25.11-py3"
sshKey="${SSH_KEY:-$HOME/.ssh/id_ed25519_cluster}"

mgmtIpA="${MGMT_IP_A:-10.0.0.11}"
mgmtIpB="${MGMT_IP_B:-10.0.0.12}"
cx7IpA="${CX7_IP_A:-10.10.0.1}"
cx7IpB="${CX7_IP_B:-10.10.0.2}"
rpcPort="50053"
serverPort="8100"
remoteUser="${REMOTE_USER:-mluser}"
remoteLlamaDir="${REMOTE_LLAMA_DIR:-/opt/gb10-cluster/llama.cpp}"
linkCapacityGbps="${LINK_CAPACITY_GBPS:-200}"
contextSize="4096"

# Constante materielle : sur l'architecture Grace Blackwell (memoire unifiee), nvidia-smi ne rapporte
# PAS memory.total/used/free (champs N/A) sur certaines versions de driver. La source fiable observee
# est le log ggml_cuda_init de llama.cpp ("Total VRAM: ... MiB"), identique sur des noeuds au materiel
# identique. Surchargeable via la variable d'environnement TOTAL_VRAM_MIB.
totalVramMib="${TOTAL_VRAM_MIB:-124544}"

modelPath="${1:-}"
safetyMarginMib="${2:-8192}"
nGen="${3:-128}"
criticalFloorMib="${4:-6144}"
checkIntervalSec="${5:-15}"
swapAlertMib="${6:-3072}"

localIps="$(ip -4 -br addr show 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
role="A"
if echo "$localIps" | grep -qx "$mgmtIpB"; then
    role="B"
fi

if [[ "$role" == "A" ]]; then
    peerSsh="$remoteUser@$mgmtIpB"
    localCx7="$cx7IpA"
    peerCx7="$cx7IpB"
    peerRole="B"
else
    peerSsh="$remoteUser@$mgmtIpA"
    localCx7="$cx7IpB"
    peerCx7="$cx7IpA"
    peerRole="A"
fi

remoteExec() {
    ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" "$1"
}

localCx7Iface="$(ip -4 -br addr show 2>/dev/null | awk -v ip="$localCx7" '$3 ~ "^"ip"/" {print $1}')"
remoteCx7Iface="$(remoteExec "ip -4 -br addr show" | awk -v ip="$peerCx7" '$3 ~ "^"ip"/" {print $1}')"
if [[ -z "$localCx7Iface" || -z "$remoteCx7Iface" ]]; then
    echo "Impossible de detecter l'interface CX7 locale/distante." >&2
    exit 1
fi

echo "Role local : Node-$role ($localCx7 / $localCx7Iface), pair : Node-$peerRole ($peerCx7 / $remoteCx7Iface)"

# --- Capacite reellement utilisable sur chaque noeud, au moment present ---
# IMPORTANT : sur Grace Blackwell, la VRAM et la RAM systeme partagent le MEME pool physique (memoire
# unifiee). nvidia-smi --query-compute-apps ne voit que les allocations attribuees aux processus CUDA :
# il ignore la pression memoire causee par les AUTRES processus (CPU) du noeud (ex : d'autres charges
# applicatives non-GPU sur un noeud partage). Se baser uniquement la-dessus peut conduire a un
# "CUDA error: out of memory" alors que le calcul GPU seul indiquait de la marge. La vraie limite a
# respecter est MemAvailable (systeme, /proc/meminfo), qui inclut deja le cache reclamable et reflete
# la pression memoire reelle, tous processus confondus (voir docs/troubleshooting.md).
usedLocalMib="$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{print s+0}')"
usedRemoteMib="$(remoteExec "nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
memAvailLocalMib="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
memAvailRemoteMib="$(remoteExec "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo")"
swapUsedLocalMib="$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)"
swapUsedRemoteMib="$(remoteExec "awk '/SwapTotal/{t=\$2} /SwapFree/{f=\$2} END{print int((t-f)/1024)}' /proc/meminfo")"

freeLocalMib=$((memAvailLocalMib - safetyMarginMib))
freeRemoteMib=$((memAvailRemoteMib - safetyMarginMib))
[[ "$freeLocalMib" -lt 0 ]] && freeLocalMib=0
[[ "$freeRemoteMib" -lt 0 ]] && freeRemoteMib=0
combinedUsableMib=$((freeLocalMib + freeRemoteMib))

printf 'Node-%s (local)  : VRAM processus CUDA %d MiB, RAM systeme disponible %d MiB, marge %d MiB -> utilisable %d MiB (%.1f GiB)\n' \
    "$role" "$usedLocalMib" "$memAvailLocalMib" "$safetyMarginMib" "$freeLocalMib" "$(awk -v m="$freeLocalMib" 'BEGIN{print m/1024}')"
printf 'Node-%s (distant): VRAM processus CUDA %d MiB, RAM systeme disponible %d MiB, marge %d MiB -> utilisable %d MiB (%.1f GiB)\n' \
    "$peerRole" "$usedRemoteMib" "$memAvailRemoteMib" "$safetyMarginMib" "$freeRemoteMib" "$(awk -v m="$freeRemoteMib" 'BEGIN{print m/1024}')"
printf 'Budget combine utilisable maintenant : %d MiB (~%.1f GiB) sur %d MiB (~%.1f GiB) combines au total\n' \
    "$combinedUsableMib" "$(awk -v m="$combinedUsableMib" 'BEGIN{print m/1024}')" \
    "$((totalVramMib * 2))" "$(awk -v m="$totalVramMib" 'BEGIN{print m*2/1024}')"
if [[ "$swapUsedLocalMib" -gt 2048 ]]; then
    echo "ATTENTION : Node-$role utilise deja ${swapUsedLocalMib} MiB de swap -- signe de pression memoire, marge de securite a prendre au serieux." >&2
fi
if [[ "$swapUsedRemoteMib" -gt 2048 ]]; then
    echo "ATTENTION : Node-$peerRole utilise deja ${swapUsedRemoteMib} MiB de swap -- signe de pression memoire, marge de securite a prendre au serieux." >&2
fi

if [[ -z "$modelPath" ]]; then
    echo "Mode diagnostic (aucun modele fourni) : capacite utilisable affichee ci-dessus, aucun conteneur demarre."
    exit 0
fi

if [[ ! -f "$modelPath" ]]; then
    echo "Modele introuvable : $modelPath" >&2
    exit 1
fi
modelAbsPath="$(cd "$(dirname "$modelPath")" && pwd)/$(basename "$modelPath")"
modelDir="$(dirname "$modelAbsPath")"
modelFile="$(basename "$modelAbsPath")"

# Modele decoupe en plusieurs fichiers (convention HuggingFace -NNNNN-of-NNNNN.gguf) : sommer les parties.
totalBytes=0
partCount=0
if [[ "$modelFile" =~ ^(.*)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
    baseName="${BASH_REMATCH[1]}"
    totalParts="${BASH_REMATCH[3]}"
    for part in "$modelDir/$baseName"-*-of-"$totalParts".gguf; do
        [[ -f "$part" ]] || continue
        totalBytes=$((totalBytes + $(stat -c%s "$part")))
        partCount=$((partCount + 1))
    done
    if [[ "$partCount" -ne "$((10#$totalParts))" ]]; then
        echo "Attention : $partCount partie(s) trouvee(s) sur $totalParts attendues pour $baseName -- modele incomplet ?" >&2
    fi
else
    totalBytes=$(stat -c%s "$modelAbsPath")
    partCount=1
fi
modelMib=$((totalBytes / 1024 / 1024))

printf 'Modele : %s (%d partie(s), %d MiB, ~%.1f GiB)\n' "$modelFile" "$partCount" "$modelMib" "$(awk -v m="$modelMib" 'BEGIN{print m/1024}')"

if [[ "$modelMib" -gt "$combinedUsableMib" ]]; then
    deficitMib=$((modelMib - combinedUsableMib))
    echo "ECHEC : modele trop volumineux pour la capacite utilisable actuelle (depassement ~${deficitMib} MiB, ~$(awk -v m="$deficitMib" 'BEGIN{printf "%.1f", m/1024}') GiB)." >&2
    echo "Reduire la marge de securite, liberer de la memoire sur Node-$peerRole, ou choisir un modele/quantification plus petit." >&2
    exit 1
fi
if [[ "$freeRemoteMib" -lt 1024 ]]; then
    echo "ECHEC : moins de 1 GiB utilisable sur Node-$peerRole en ce moment -- offload RPC non sur, test non distribue par securite." >&2
    exit 1
fi

echo "Repartition ciblee (proportionnelle a la memoire utilisable du moment) : -ts $freeLocalMib,$freeRemoteMib"

cleanup() {
    echo "--- Nettoyage ---"
    sg docker -c "docker rm -f llama_server_scale" >/dev/null 2>&1 || true
    remoteExec "sudo docker rm -f llama_rpc_scale" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- Demarrage du worker RPC GPU distant sur $peerCx7:$rpcPort ---"
remoteExec "sudo docker rm -f llama_rpc_scale >/dev/null 2>&1; sudo docker run -d --gpus all --network host -v $remoteLlamaDir:/workspace -w /workspace --name llama_rpc_scale $image ./build/bin/ggml-rpc-server --host $peerCx7 --port $rpcPort" >/dev/null

echo "Attente de l'ouverture du port RPC distant (max 30s)..."
rpcReady=0
for _ in $(seq 1 15); do
    if timeout 1 bash -c "echo > /dev/tcp/$peerCx7/$rpcPort" 2>/dev/null; then
        rpcReady=1
        break
    fi
    sleep 2
done
if [[ "$rpcReady" -ne 1 ]]; then
    echo "Le worker RPC distant n'a pas ouvert son port a temps." >&2
    remoteExec "sudo docker logs llama_rpc_scale" 2>&1 | tail -30 >&2 || true
    exit 1
fi

readLinkCounters() {
    # $1 = interface ; affiche "rxBytes txBytes"
    ip -s link show "$1" | awk '/RX:/{getline; rx=$1} /TX:/{getline; tx=$1} END{print rx, tx}'
}

read -r rxLocalBefore txLocalBefore <<<"$(readLinkCounters "$localCx7Iface")"
read -r rxRemoteBefore txRemoteBefore <<<"$(remoteExec "ip -s link show $remoteCx7Iface" | awk '/RX:/{getline; rx=$1} /TX:/{getline; tx=$1} END{print rx, tx}')"

# Snapshot VRAM distante AVANT (pour verifier plus tard que les processus preexistants ne sont pas impactes)
remoteBeforeSnapshot="$(remoteExec "nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits" 2>/dev/null || true)"

# Re-verification periodique PENDANT le chargement : un check ponctuel avant le chargement ne suffit
# pas pour un noeud partage/volatil sur une operation de plusieurs minutes -- sa charge peut se
# degrader fortement entre-temps (voir docs/troubleshooting.md). Retourne 1 (et affiche la raison) si
# un plancher critique absolu est franchi ou si le swap distant augmente trop depuis le debut du test ;
# l'appelant doit alors arreter immediatement (le trap cleanup se charge de tuer les conteneurs avant
# qu'un vrai OOM-killer ne frappe des processus existants).
abortIfUnsafe() {
    local curMemAvailLocal curMemAvailRemote curSwapRemote
    curMemAvailLocal="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
    curMemAvailRemote="$(remoteExec "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null)"
    curSwapRemote="$(remoteExec "awk '/SwapTotal/{t=\$2} /SwapFree/{f=\$2} END{print int((t-f)/1024)}' /proc/meminfo" 2>/dev/null)"

    if [[ -z "$curMemAvailRemote" ]]; then
        echo "ABORT PREVENTIF : impossible de verifier la memoire distante (Node-$peerRole injoignable ?)." >&2
        return 1
    fi
    if [[ "$curMemAvailLocal" -lt "$criticalFloorMib" ]]; then
        echo "ABORT PREVENTIF : MemAvailable local Node-$role descendu a ${curMemAvailLocal} MiB (< plancher critique ${criticalFloorMib} MiB)." >&2
        return 1
    fi
    if [[ "$curMemAvailRemote" -lt "$criticalFloorMib" ]]; then
        echo "ABORT PREVENTIF : MemAvailable distant Node-$peerRole descendu a ${curMemAvailRemote} MiB (< plancher critique ${criticalFloorMib} MiB) -- risque d'OOM imminent." >&2
        return 1
    fi
    if [[ -n "$curSwapRemote" && "$curSwapRemote" -gt "$((swapUsedRemoteMib + swapAlertMib))" ]]; then
        echo "ABORT PREVENTIF : swap distant Node-$peerRole en forte hausse depuis le debut du test (${swapUsedRemoteMib} -> ${curSwapRemote} MiB, seuil ${swapAlertMib} MiB) -- pression memoire en degradation rapide." >&2
        return 1
    fi
    return 0
}

echo "--- Chargement du modele (${modelMib} MiB) reparti sur les deux noeuds ---"
sg docker -c "docker rm -f llama_server_scale >/dev/null 2>&1; docker run -d --gpus all --network host \
    -v $llamaDir:/workspace -v $modelDir:/models -w /workspace \
    --name llama_server_scale $image \
    ./build/bin/llama-server -m /models/$modelFile \
    --rpc $peerCx7:$rpcPort -ngl 99 -ts $freeLocalMib,$freeRemoteMib -c $contextSize \
    --host 0.0.0.0 --port $serverPort" >/dev/null

loadStart="$(date +%s.%N)"
echo "Attente de la fin du chargement (health check, pas de limite de temps vu la taille du modele)..."
echo "Re-verification memoire toutes les ${checkIntervalSec}s (plancher critique ${criticalFloorMib} MiB, alerte swap +${swapAlertMib} MiB)."
loaded=0
elapsedPrint=0
nextCheckAt="$checkIntervalSec"
while true; do
    if curl -s -f -o /dev/null "http://127.0.0.1:$serverPort/health" 2>/dev/null; then
        loaded=1
        break
    fi
    if ! sg docker -c "docker inspect -f '{{.State.Running}}' llama_server_scale" 2>/dev/null | grep -q true; then
        echo "Le conteneur local s'est arrete de maniere inattendue pendant le chargement." >&2
        sg docker -c "docker logs llama_server_scale" 2>&1 | tail -40 >&2 || true
        exit 1
    fi
    if (( elapsedPrint >= nextCheckAt )); then
        if ! abortIfUnsafe; then
            echo "Arret preventif (${elapsedPrint}s ecoulees) pour proteger Node-$peerRole avant qu'un OOM reel ne survienne." >&2
            exit 1
        fi
        nextCheckAt=$((nextCheckAt + checkIntervalSec))
    fi
    sleep 5
    elapsedPrint=$((elapsedPrint + 5))
    if (( elapsedPrint % 30 == 0 )); then
        echo "... chargement en cours (${elapsedPrint}s ecoulees)"
    fi
done
loadEnd="$(date +%s.%N)"
loadSeconds="$(awk -v a="$loadEnd" -v b="$loadStart" 'BEGIN{printf "%.2f", a-b}')"

read -r rxLocalAfter txLocalAfter <<<"$(readLinkCounters "$localCx7Iface")"
read -r rxRemoteAfter txRemoteAfter <<<"$(remoteExec "ip -s link show $remoteCx7Iface" | awk '/RX:/{getline; rx=$1} /TX:/{getline; tx=$1} END{print rx, tx}')"

deltaTxLocal=$((txLocalAfter - txLocalBefore))
deltaRxRemote=$((rxRemoteAfter - rxRemoteBefore))

echo "--- Resultat du chargement ---"
printf 'Temps de chargement : %s s\n' "$loadSeconds"
printf 'Octets emis par Node-%s (local, TX)   : %d (%.2f GiB)\n' "$role" "$deltaTxLocal" "$(awk -v b="$deltaTxLocal" 'BEGIN{print b/1024/1024/1024}')"
printf 'Octets recus par Node-%s (distant, RX): %d (%.2f GiB)\n' "$peerRole" "$deltaRxRemote" "$(awk -v b="$deltaRxRemote" 'BEGIN{print b/1024/1024/1024}')"
awk -v b="$deltaTxLocal" -v s="$loadSeconds" -v cap="$linkCapacityGbps" 'BEGIN{
    if (s<=0) { print "Debit TX local : indetermine (duree nulle)"; exit }
    gbps = (b*8)/(s*1000*1000*1000)
    printf "Debit TX local pendant le chargement : %.2f Gb/s (%.1f%% du debit nominal %s Gb/s du lien CX7)\n", gbps, (gbps/cap)*100, cap
}'
expectedRemoteMib=$(( modelMib * freeRemoteMib / (freeLocalMib + freeRemoteMib) ))
printf 'Part distante attendue (proportionnelle a -ts) : ~%d MiB -- mesuree (RX distant) : %.0f MiB\n' \
    "$expectedRemoteMib" "$(awk -v b="$deltaRxRemote" 'BEGIN{print b/1024/1024}')"

echo "--- VRAM locale (Node-$role) apres chargement ---"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null || true
echo "--- VRAM distante (Node-$peerRole) apres chargement ---"
remoteAfterSnapshot="$(remoteExec "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv" 2>/dev/null || true)"
echo "$remoteAfterSnapshot"

echo "--- Verification de non-perturbation des charges preexistantes sur Node-$peerRole ---"
disrupted=0
while IFS=',' read -r pid mem; do
    pid="$(echo "$pid" | xargs)"; mem="$(echo "$mem" | xargs)"
    [[ -z "$pid" ]] && continue
    newMem="$(echo "$remoteAfterSnapshot" | awk -F',' -v p="$pid" '{gsub(/ /,"",$1); gsub(/ MiB/,"",$3); if ($1+0==p+0) print $3+0}')"
    if [[ -n "$newMem" && "$newMem" != "$mem" ]]; then
        echo "ATTENTION : processus pid=$pid present avant le test a change de VRAM (${mem} -> ${newMem} MiB)." >&2
        disrupted=1
    fi
done <<<"$remoteBeforeSnapshot"
if [[ "$disrupted" -eq 0 ]]; then
    echo "OK : aucune charge preexistante sur Node-$peerRole n'a vu sa VRAM changer."
fi

echo "--- Debit d'inference (prompt + generation), $nGen tokens generes ---"
curl -s "http://127.0.0.1:$serverPort/completion" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\":\"Decris en une phrase le fonctionnement d'un reseau de neurones.\",\"n_predict\":$nGen,\"temperature\":0}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
t = d.get('timings', {})
print(f\"Prompt     : {t.get('prompt_per_second', 0):.2f} t/s ({t.get('prompt_n', 0)} tokens, {t.get('prompt_ms', 0):.0f} ms)\")
print(f\"Generation : {t.get('predicted_per_second', 0):.2f} t/s ({t.get('predicted_n', 0)} tokens, {t.get('predicted_ms', 0):.0f} ms)\")
"

echo "Termine."
