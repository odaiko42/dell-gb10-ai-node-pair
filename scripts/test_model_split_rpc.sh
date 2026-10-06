#!/usr/bin/env bash
# Smoke test de chargement de modele reparti sur deux noeuds via llama.cpp (backend RPC).
# Demarre le worker GPU distant (rpc-server) sur Node-B, puis llama-server sur le noeud local
# avec offload des couches vers B, envoie un prompt deterministe et verifie la VRAM utilisee
# sur les deux noeuds pour prouver le partitionnement reel du modele.
#
# Usage : ./test_model_split_rpc.sh [chemin_modele.gguf]
#   Par defaut : models/qwen2.5-3b-instruct-q4_k_m.gguf (petit modele de test)
#   Pour un modele plus gros : ./test_model_split_rpc.sh /chemin/vers/gros_modele.gguf
#
# Configuration reseau/identite via variables d'environnement (voir defauts ci-dessous).

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
llamaDir="$scriptDir/llama.cpp"
modelPath="${1:-$scriptDir/models/qwen2.5-3b-instruct-q4_k_m.gguf}"
image="nvcr.io/nvidia/pytorch:25.11-py3"
sshKey="${SSH_KEY:-$HOME/.ssh/id_ed25519_cluster}"

mgmtIpA="${MGMT_IP_A:-10.0.0.11}"
mgmtIpB="${MGMT_IP_B:-10.0.0.12}"
cx7IpA="${CX7_IP_A:-10.10.0.1}"
cx7IpB="${CX7_IP_B:-10.10.0.2}"
rpcPort="50052"
serverPort="8099"
remoteUser="${REMOTE_USER:-mluser}"
remoteLlamaDir="${REMOTE_LLAMA_DIR:-/opt/gb10-cluster/llama.cpp}"

localIps="$(ip -4 -br addr show 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
role="A"
if echo "$localIps" | grep -qx "$mgmtIpB"; then
    role="B"
fi

if [[ "$role" == "A" ]]; then
    peerSsh="$remoteUser@$mgmtIpB"
    localCx7="$cx7IpA"
    peerCx7="$cx7IpB"
else
    peerSsh="$remoteUser@$mgmtIpA"
    localCx7="$cx7IpB"
    peerCx7="$cx7IpA"
fi

echo "Role local detecte : Node-$role ($localCx7), pair Node-$([[ $role == A ]] && echo B || echo A) ($peerCx7)"

if [[ ! -f "$modelPath" ]]; then
    echo "Modele introuvable : $modelPath" >&2
    echo "Telecharger un modele GGUF avant de relancer (ex: Qwen2.5-3B-Instruct-GGUF Q4_K_M)." >&2
    exit 1
fi

echo "--- Demarrage du worker RPC GPU distant sur le pair ($peerCx7:$rpcPort) ---"
ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" \
    "sudo docker rm -f llama_rpc_peer >/dev/null 2>&1; sudo docker run -d --gpus all --network host -v $remoteLlamaDir:/workspace -w /workspace --name llama_rpc_peer $image ./build/bin/ggml-rpc-server --host $peerCx7 --port $rpcPort" >/dev/null

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

cleanup() {
    echo "--- Nettoyage ---"
    sg docker -c "docker rm -f llama_server_local" >/dev/null 2>&1 || true
    ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" "sudo docker rm -f llama_rpc_peer" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- Chargement du modele reparti sur le noeud local avec offload vers $peerCx7:$rpcPort ---"
sg docker -c "docker run --rm -d --gpus all --network host \
    -v $llamaDir:/workspace -v $scriptDir/models:/models -w /workspace \
    --name llama_server_local $image \
    ./build/bin/llama-server -m /models/$(basename "$modelPath") \
    --rpc $peerCx7:$rpcPort -ngl 99 --host 0.0.0.0 --port $serverPort" >/dev/null

echo "Attente du chargement (max 120s)..."
for _ in $(seq 1 60); do
    if curl -s -f -o /dev/null "http://127.0.0.1:$serverPort/health" 2>/dev/null; then
        break
    fi
    sleep 2
done

echo "--- VRAM utilisee localement (Node-$role) ---"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null || true

echo "--- VRAM utilisee chez le pair (offload RPC) ---"
ssh -i "$sshKey" -o BatchMode=yes "$peerSsh" \
    "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv" 2>/dev/null || true

echo "--- Test d'inference (prompt deterministe) ---"
curl -s "http://127.0.0.1:$serverPort/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Combien font 6 fois 7 ? Reponds uniquement par le nombre."}],"temperature":0,"max_tokens":10}' \
    | python3 -c "import sys,json; print('Reponse du modele :', json.load(sys.stdin)['choices'][0]['message']['content'])"

echo "Termine. Si le processus rpc-server distant affiche une VRAM > 0, le modele est bien reparti sur les deux noeuds."
