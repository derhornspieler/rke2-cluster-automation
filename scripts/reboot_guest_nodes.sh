#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-${REPO_ROOT}/rke2.kubeconfig}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-}"
NAMESPACE="${HARVESTER_NAMESPACE:-rke2}"
NODE_SELECTOR="${NODE_SELECTOR:-}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-5m}"

usage() {
  cat <<'EOF'
Usage: scripts/reboot_guest_nodes.sh [--node-selector key=value]

Gracefully cordon/drain guest nodes, restart their VMIs in Harvester, then wait for nodes to become Ready and uncordon.

Environment variables:
  GUEST_KUBECONFIG   Kubeconfig for the guest cluster (default: ./rke2.kubeconfig).
  MGMT_KUBECONFIG    Kubeconfig for Harvester management cluster (default: current kubectl context).
  HARVESTER_NAMESPACE Namespace containing the guest VMs (default: rke2).
  NODE_SELECTOR      Optional node label selector to filter which nodes to reboot.
  DRAIN_TIMEOUT      Timeout for kubectl drain (default: 5m).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-selector) NODE_SELECTOR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }
}

log() {
  local ts
  ts="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  printf '[%s] %s\n' "${ts}" "$*"
}

require_bin kubectl

guest_k() { KUBECONFIG="${GUEST_KUBECONFIG}" kubectl "$@"; }
mgmt_k() {
  if [[ -n "${MGMT_KUBECONFIG}" ]]; then
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl "$@"
  else
    kubectl "$@"
  fi
}

log "Selecting guest nodes${NODE_SELECTOR:+ with selector ${NODE_SELECTOR}}."
mapfile -t NODES < <(guest_k get nodes ${NODE_SELECTOR:+-l "${NODE_SELECTOR}"} -o jsonpath='{.items[*].metadata.name}')
if ((${#NODES[@]} == 0)); then
  log "No nodes matched; exiting."
  exit 0
fi

for node in "${NODES[@]}"; do
  log "Processing node ${node}"
  guest_k cordon "${node}" || true
  guest_k drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout="${DRAIN_TIMEOUT}" || true

  log "Restarting VMI for ${node} in namespace ${NAMESPACE}"
  mgmt_k -n "${NAMESPACE}" delete vmi "${node}" --ignore-not-found

  log "Waiting for VMI ${node} to become Running with IP."
  start=$(date +%s)
  while true; do
    phase=$(mgmt_k -n "${NAMESPACE}" get vmi "${node}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ip=$(mgmt_k -n "${NAMESPACE}" get vmi "${node}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)
    if [[ "${phase}" == "Running" && -n "${ip}" ]]; then
      log "VMI ${node} Running at IP ${ip}."
      break
    fi
    if (( $(date +%s) - start > 600 )); then
      log "Timeout waiting for VMI ${node} to become Running."
      exit 1
    fi
    sleep 5
  done

  log "Waiting for guest node ${node} to become Ready."
  if ! guest_k wait --for=condition=Ready node/"${node}" --timeout=600s; then
    log "Node ${node} did not return to Ready in time."
    exit 1
  fi
  guest_k uncordon "${node}" || true
  log "Node ${node} reboot workflow completed."
done

log "All selected nodes processed."
