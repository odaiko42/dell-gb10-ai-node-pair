#!/usr/bin/env bash
# Benchmark de charge/debit d'un modele reparti sur deux noeuds via llama.cpp (backend RPC).
# Complement de test_model_split_rpc.sh (qui valide la correction) : ce script mesure le debit
# prompt-processing / token-generation et la VRAM reellement utilisee sur chaque noeud, utile
# pour evaluer un modele dont la taille approche ou depasse la capacite d'un seul noeud.
#
# Usage : ./bench_model_split_rpc.sh <chemin_modele.gguf> [n_prompt] [n_gen] [repetitions]
#   <chemin_modele.gguf>  Obligatoire. Modele GGUF a tester (local, mappe dans ./models).
#   [n_prompt]            Taille du prompt simule (defaut: 512)
#   [n_gen]               Nombre de tokens generes mesures (defaut: 128)
#   [repetitions]         Repetitions par mesure (defaut: 3)
#
# Configuration reseau/identite via variables d'environnement (voir defauts ci-dessous).
#
# Exemple :
#   ./bench_model_split_rpc.sh models/qwen2.5-14b-instruct-q4_k_m-00001-of-00003.gguf 512 128 3

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
llamaDir="$scriptDir/llama.cpp"
image="nvcr.io/nvidia/pytorch:25.11-py3"
sshKey="${SSH_KEY:-$HOME/.ssh/id_ed25519_cluster}"

mgmtIpA="${MGMT_IP_A:-10.0.0.11}"
mgmtIpB="${MGMT_IP_B:-10.0.0.12}"
cx7IpA="${CX7_IP_A:-10.10.0.1}"
cx7IpB="${CX7_IP_B:-10.10.0.2}"
rpcPort="50052"
remoteUser="${REMOTE_USER:-mluser}"
remoteLlamaDir="${REMOTE_LLAMA_DIR:-/opt/gb10-cluster/llama.cpp}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <chemin_modele.gguf> [n_prompt] [n_gen] [repetitions]" >&2
    exit 1
fi
modelPath="$1"
nPrompt="${2:-512}"
nGen="${3:-128}"
repetitions="${4:-3}"

if [[ ! -f "$modelPath" ]]; then
    echo "Modele introuvable : $modelPath" >&2
    exit 1
fi
modelAbsPath="$(cd "$(dirname "$modelPath")" && pwd)/$(basename "$modelPath")"
modelDir="$(dirname "$modelAbsPath")"
modelFile="$(basename "$modelAbsPath")"

localIps="$(ip -4 -br addr show 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
role="A"
if echo "$localIps" | grep -qx "$mgmtIpB"; then
    role="B"
fi

if [[ "$role" == "A" ]]; then
    peerSsh="$remoteUser@$mgmtIpB"
    peerCx7="$cx7IpB"
else
    peerSsh="$remoteUser@$mgmtIpA"
    peerCx7="$cx7IpA"
fi

echo "Role local : Node-$role, pair : $peerCx7 ($peerSsh)"
echo "Modele     : $modelFile ($(du -h "$modelAbsPath" | cut -f1))"
echo "Mesure     : n_prompt=$nPrompt n_gen=$nGen repetitions=$repetitions"

cleanup() {
    echo "--- Nettoyage ---"
    sg docker -c "docker rm -f llama_bench_local" >/dev/null 2>&1 || true
    ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" "sudo docker rm -f llama_rpc_bench" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- Demarrage du worker RPC GPU distant sur $peerCx7:$rpcPort ---"
ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" \
    "sudo docker rm -f llama_rpc_bench >/dev/null 2>&1; sudo docker run -d --gpus all --network host -v $remoteLlamaDir:/workspace -w /workspace --name llama_rpc_bench $image ./build/bin/ggml-rpc-server --host $peerCx7 --port $rpcPort" >/dev/null

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
    exit 1
fi

echo "--- Benchmark local+distant (llama-bench), modele $modelFile ---"
sg docker -c "docker rm -f llama_bench_local >/dev/null 2>&1; docker run -d --gpus all --network host \
    -v $llamaDir:/workspace -v $modelDir:/models -w /workspace --name llama_bench_local $image \
    ./build/bin/llama-bench -m /models/$modelFile \
    -rpc $peerCx7:$rpcPort -ngl 99 \
    -p $nPrompt -n $nGen -r $repetitions -o md" >/dev/null

echo "Benchmark en cours (chargement du modele puis mesures, patience selon la taille)..."
sleep 10
echo "--- VRAM locale (Node-$role) pendant le benchmark ---"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null || true
echo "--- VRAM distante (noeud pair) pendant le benchmark ---"
ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" \
    "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv" 2>/dev/null || true

echo "--- Attente de la fin du benchmark et resultats ---"
sg docker -c "docker wait llama_bench_local" >/dev/null
sg docker -c "docker logs llama_bench_local"
echo "Termine."
