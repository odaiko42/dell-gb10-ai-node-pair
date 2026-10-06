#!/usr/bin/env bash
# Valide de bout en bout la liaison dual-noeud (management, CX7, SSH, RDMA, option iperf3).
# A executer sur Node-A ou Node-B : le role local est detecte automatiquement.
#
# Toute la configuration est parametrable par variables d'environnement (voir defaut ci-dessous) :
# adapter MGMT_IP_A/B, CX7_*, SSH_USER/SSH_KEY a votre propre cluster avant execution.
set -uo pipefail

# --- Configuration : exemples de valeurs, a adapter via l'environnement ---
mgmtIpA="${MGMT_IP_A:-10.0.0.11}"
mgmtIpB="${MGMT_IP_B:-10.0.0.12}"
cx7Subnet1A="${CX7_IP_A_1:-10.10.0.1}"
cx7Subnet1B="${CX7_IP_B_1:-10.10.0.2}"
cx7Subnet2A="${CX7_IP_A_2:-10.10.1.1}"
cx7Subnet2B="${CX7_IP_B_2:-10.10.1.2}"
cx7Iface1="${CX7_IFACE_1:-enp1s0f0np0}"
cx7Iface2="${CX7_IFACE_2:-enP2p1s0f0np0}"
sshUser="${SSH_USER:-mluser}"
sshKey="${SSH_KEY:-$HOME/.ssh/id_ed25519_cluster}"
sshOpts=(-i "$sshKey" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
withIperf3=0
iperf3Port=5201

for arg in "$@"; do
  case "$arg" in
    --with-iperf3) withIperf3=1 ;;
    *) echo "Option inconnue: $arg (usage: $0 [--with-iperf3])" >&2; exit 2 ;;
  esac
done

passCount=0
failCount=0
skipCount=0

logPass() { echo "[PASS] $1"; passCount=$((passCount + 1)); }
logFail() { echo "[FAIL] $1" >&2; failCount=$((failCount + 1)); }
logSkip() { echo "[SKIP] $1"; skipCount=$((skipCount + 1)); }

# Determine si ce script tourne sur Node-A ou Node-B d'apres les IP locales.
detectRole() {
  local localIps
  localIps=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
  if grep -qx "$mgmtIpA" <<<"$localIps"; then
    echo "A"
  elif grep -qx "$mgmtIpB" <<<"$localIps"; then
    echo "B"
  else
    echo "UNKNOWN"
  fi
}

checkManagementPing() {
  if ping -c 3 -W 2 "$peerMgmtIp" >/dev/null 2>&1; then
    logPass "Ping management vers le pair ($peerMgmtIp)"
  else
    logFail "Ping management vers le pair ($peerMgmtIp) injoignable"
  fi
}

checkSshKeyAuth() {
  if [[ ! -f "$sshKey" ]]; then
    logSkip "Cle SSH dediee absente ($sshKey), authentification par cle non testee"
    return
  fi
  if ssh "${sshOpts[@]}" "${sshUser}@${peerMgmtIp}" true 2>/dev/null; then
    logPass "Authentification SSH par cle vers le pair ($peerMgmtIp)"
  else
    logFail "Authentification SSH par cle vers le pair ($peerMgmtIp) refusee"
  fi
}

checkCx7Interfaces() {
  local iface expectedIp actualIp state
  for pair in "$cx7Iface1:$localCx7_1" "$cx7Iface2:$localCx7_2"; do
    iface="${pair%%:*}"
    expectedIp="${pair##*:}"
    state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
    actualIp=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [[ "$state" == "UP" && "$actualIp" == "$expectedIp" ]]; then
      logPass "Interface CX7 $iface Up avec IP $expectedIp"
    else
      logFail "Interface CX7 $iface etat='$state' ip='$actualIp' (attendu UP / $expectedIp)"
    fi
  done
}

checkCx7Ping() {
  if ping -c 3 -W 2 "$peerCx7_1" >/dev/null 2>&1; then
    logPass "Ping CX7 lien 1 vers $peerCx7_1"
  else
    logFail "Ping CX7 lien 1 vers $peerCx7_1 injoignable"
  fi
  if ping -c 3 -W 2 "$peerCx7_2" >/dev/null 2>&1; then
    logPass "Ping CX7 lien 2 vers $peerCx7_2"
  else
    logFail "Ping CX7 lien 2 vers $peerCx7_2 injoignable"
  fi
}

checkRdma() {
  if ! command -v rdma >/dev/null 2>&1; then
    logSkip "Commande rdma absente, etat RDMA non verifie"
    return
  fi
  local activeCount
  activeCount=$(rdma link show 2>/dev/null | grep -c "state ACTIVE")
  if [[ "$activeCount" -ge 2 ]]; then
    logPass "RDMA: $activeCount lien(s) ACTIVE detecte(s) localement"
  else
    logFail "RDMA: seulement $activeCount lien(s) ACTIVE (attendu >= 2)"
  fi
}

checkGpuLocal() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    logPass "GPU visible localement via nvidia-smi"
  else
    logFail "nvidia-smi indisponible ou en echec localement"
  fi
}

checkGpuPeer() {
  if [[ ! -f "$sshKey" ]]; then
    logSkip "Pas de cle SSH, GPU distant non verifie"
    return
  fi
  if ssh "${sshOpts[@]}" "${sshUser}@${peerMgmtIp}" 'nvidia-smi >/dev/null 2>&1'; then
    logPass "GPU visible cote pair via nvidia-smi"
  else
    logFail "nvidia-smi indisponible ou en echec cote pair"
  fi
}

# Test de bande passante optionnel : serveur iperf3 lance cote pair via SSH, arrete apres mesure.
checkIperf3() {
  if [[ "$withIperf3" -ne 1 ]]; then
    logSkip "Test iperf3 non demande (ajouter --with-iperf3 pour l'activer)"
    return
  fi
  if ! command -v iperf3 >/dev/null 2>&1; then
    logSkip "iperf3 absent localement, test debit non realise"
    return
  fi
  if [[ ! -f "$sshKey" ]]; then
    logSkip "Pas de cle SSH, test iperf3 distant non realise"
    return
  fi
  if ! ssh "${sshOpts[@]}" "${sshUser}@${peerMgmtIp}" 'command -v iperf3' >/dev/null 2>&1; then
    logSkip "iperf3 absent cote pair, test debit non realise"
    return
  fi

  ssh "${sshOpts[@]}" "${sshUser}@${peerMgmtIp}" \
    "nohup iperf3 -s -B ${peerCx7_1} -p ${iperf3Port} -1 >/tmp/iperf3-cluster-test.log 2>&1 &" >/dev/null 2>&1
  sleep 2

  local result
  if result=$(iperf3 -c "$peerCx7_1" -B "$localCx7_1" -p "$iperf3Port" -t 5 -J 2>/dev/null); then
    local bitsPerSecond
    bitsPerSecond=$(echo "$result" | grep -o '"bits_per_second":[0-9.]*' | tail -1 | cut -d: -f2)
    if [[ -n "$bitsPerSecond" ]]; then
      logPass "iperf3 CX7 lien 1: $(awk -v b="$bitsPerSecond" 'BEGIN{printf "%.1f Gb/s", b/1000000000}')"
    else
      logFail "iperf3 CX7 lien 1: resultat inexploitable"
    fi
  else
    logFail "iperf3 CX7 lien 1: echec de connexion vers $peerCx7_1"
  fi

  ssh "${sshOpts[@]}" "${sshUser}@${peerMgmtIp}" "pkill -f 'iperf3 -s -B ${peerCx7_1}'" >/dev/null 2>&1 || true
}

printSummary() {
  echo "----------------------------------------"
  echo "Resume : $passCount PASS, $failCount FAIL, $skipCount SKIP"
  echo "----------------------------------------"
}

role=$(detectRole)
case "$role" in
  A)
    peerMgmtIp="$mgmtIpB"
    localCx7_1="$cx7Subnet1A"; peerCx7_1="$cx7Subnet1B"
    localCx7_2="$cx7Subnet2A"; peerCx7_2="$cx7Subnet2B"
    echo "Role detecte : Node-A (local), pair Node-B ($peerMgmtIp)"
    ;;
  B)
    peerMgmtIp="$mgmtIpA"
    localCx7_1="$cx7Subnet1B"; peerCx7_1="$cx7Subnet1A"
    localCx7_2="$cx7Subnet2B"; peerCx7_2="$cx7Subnet2A"
    echo "Role detecte : Node-B (local), pair Node-A ($peerMgmtIp)"
    ;;
  *)
    echo "Impossible de determiner si ce script tourne sur Node-A ou Node-B (IP locale non reconnue)." >&2
    exit 2
    ;;
esac
echo "----------------------------------------"

checkManagementPing
checkSshKeyAuth
checkCx7Interfaces
checkCx7Ping
checkRdma
checkGpuLocal
checkGpuPeer
checkIperf3

printSummary

[[ "$failCount" -eq 0 ]]
