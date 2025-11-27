#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-${REPO_ROOT}/rke2.kubeconfig}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-}"
NAMESPACE="${HARVESTER_NAMESPACE:-rke2}"
NODE_SELECTOR="${NODE_SELECTOR:-}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-5m}"
GUEST_CONTEXT="${GUEST_CONTEXT:-}"
MGMT_CONTEXT="${MGMT_CONTEXT:-}"
VIP_ENDPOINT="${VIP_ENDPOINT:-}"
DRAIN_NODES="${DRAIN_NODES:-false}"

usage() {
  cat <<'EOF'
Usage: scripts/reboot_guest_nodes.sh [--node-selector key=value]

Gracefully cordon/drain guest nodes, restart their VMIs in Harvester, then wait for nodes to become Ready and uncordon.

Environment variables:
  GUEST_KUBECONFIG   Kubeconfig for the guest cluster (default: ./rke2.kubeconfig).
  GUEST_CONTEXT      Optional kubectl context name to use with the guest kubeconfig.
  MGMT_KUBECONFIG    Kubeconfig for Harvester management cluster (default: current kubectl context).
  MGMT_CONTEXT       Optional kubectl context name to use with the management kubeconfig.
  HARVESTER_NAMESPACE Namespace containing the guest VMs (default: rke2).
  NODE_SELECTOR      Optional node label selector to filter which nodes to reboot.
  DRAIN_TIMEOUT      Timeout for kubectl drain (default: 5m).
  VIP_ENDPOINT       API VIP host:port for health checks (default: derived from guest kubeconfig server).
  DRAIN_NODES        Set to true to drain nodes before reboot (default: false; only cordon/reboot).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guest-kubeconfig) GUEST_KUBECONFIG="$2"; shift 2 ;;
    --guest-context) GUEST_CONTEXT="$2"; shift 2 ;;
    --mgmt-kubeconfig) MGMT_KUBECONFIG="$2"; shift 2 ;;
    --mgmt-context) MGMT_CONTEXT="$2"; shift 2 ;;
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

if [[ ! -f "${GUEST_KUBECONFIG}" ]]; then
  echo "Guest kubeconfig ${GUEST_KUBECONFIG} not found; set GUEST_KUBECONFIG to a valid path." >&2
  exit 1
fi
if [[ -n "${MGMT_KUBECONFIG}" && ! -f "${MGMT_KUBECONFIG}" ]]; then
  echo "Management kubeconfig ${MGMT_KUBECONFIG} not found; set MGMT_KUBECONFIG to a valid path or leave empty to use current context." >&2
  exit 1
fi

guest_k() { KUBECONFIG="${GUEST_KUBECONFIG}" kubectl ${GUEST_CONTEXT:+--context "${GUEST_CONTEXT}"} "$@"; }
mgmt_k() {
  if [[ -n "${MGMT_KUBECONFIG}" ]]; then
    KUBECONFIG="${MGMT_KUBECONFIG}" kubectl ${MGMT_CONTEXT:+--context "${MGMT_CONTEXT}"} "$@"
  else
    KUBECONFIG="" kubectl ${MGMT_CONTEXT:+--context "${MGMT_CONTEXT}"} "$@"
  fi
}

log "Using guest kubeconfig ${GUEST_KUBECONFIG}${GUEST_CONTEXT:+ (context ${GUEST_CONTEXT})}."
if [[ -n "${MGMT_KUBECONFIG}" ]]; then
  log "Using management kubeconfig ${MGMT_KUBECONFIG}${MGMT_CONTEXT:+ (context ${MGMT_CONTEXT})}."
else
  log "Using current kubectl context for management cluster${MGMT_CONTEXT:+ (context override ${MGMT_CONTEXT})}."
fi

log "Selecting guest nodes${NODE_SELECTOR:+ with selector ${NODE_SELECTOR}}."
mapfile -t NODES < <(guest_k get nodes ${NODE_SELECTOR:+-l "${NODE_SELECTOR}"} -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if ((${#NODES[@]} == 0)); then
  log "No nodes matched; exiting."
  exit 0
fi
log "Found nodes: ${NODES[*]}"

derive_vip() {
  local vip="${VIP_ENDPOINT}"
  if [[ -z "${vip}" ]]; then
    vip=$(guest_k config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  fi
  vip="${vip#https://}"
  vip="${vip#http://}"
  echo "${vip}"
}

wait_for_api() {
  local target="$1" tries=0
  [[ -z "${target}" ]] && return 0
  log "Waiting for API at https://${target}/version to respond."
  until curl -k --connect-timeout 3 --max-time 5 "https://${target}/version" >/dev/null 2>&1; do
    tries=$((tries+1))
    if (( tries > 60 )); then
      log "API at ${target} did not respond after 5 minutes."
      return 1
    fi
    sleep 5
  done
  log "API at ${target} is reachable."
}

VIP_ADDR="$(derive_vip)"

for node in "${NODES[@]}"; do
  log "Processing node ${node}"
  guest_k cordon "${node}" || true
  if [[ "${DRAIN_NODES}" == "true" ]]; then
    guest_k drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout="${DRAIN_TIMEOUT}" || log "Drain for ${node} encountered errors; continuing."
  else
    log "Drain skipped for ${node} (DRAIN_NODES=${DRAIN_NODES})."
  fi

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

  wait_for_api "${VIP_ADDR}" || true

  log "Waiting for guest node ${node} to become Ready."
  if ! guest_k wait --for=condition=Ready node/"${node}" --timeout=900s; then
    log "Node ${node} did not return to Ready in time."
    exit 1
  fi
  guest_k uncordon "${node}" || true
  log "Node ${node} reboot workflow completed."
done

log "All selected nodes processed."
