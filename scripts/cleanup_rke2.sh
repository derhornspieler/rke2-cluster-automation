#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${HELM_RELEASE:-rke2}"
NAMESPACE="${HARVESTER_NAMESPACE:-rke2}"
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-${REPO_ROOT}/rke2.kubeconfig}"
DELETE_IMAGES=true
DELETE_NETWORKS=true
WORKER_DRAIN_TIMEOUT="${WORKER_DRAIN_TIMEOUT:-5m}"
VM_NAME_PREFIX="${RELEASE}"
CONTROL_PLANE_COUNT=0
WORKER_COUNT=0

IMAGE_MANIFESTS=(
  "${REPO_ROOT}/manifests/image/ubuntu.yaml"
  "${REPO_ROOT}/manifests/image/rocky9.yaml"
)

NETWORK_MANIFESTS=(
  "${REPO_ROOT}/manifests/network/networks.yaml"
  "${REPO_ROOT}/manifests/network/vmnet-vlan2003-ippool.yaml"
)

usage() {
  cat <<'EOF'
Usage: scripts/cleanup_rke2.sh [options]

Options:
  --keep-images    Leave the VirtualMachineImage resources intact.
  --keep-networks  Skip deleting the Harvester network manifests.
  -h, --help       Show this help text.

Environment variables:
  HELM_RELEASE        Helm release to uninstall (default: rke2).
  HARVESTER_NAMESPACE Guest-cluster namespace (default: rke2). Set if you deployed to a non-default namespace.
  GUEST_KUBECONFIG    Path to guest cluster kubeconfig for cordon/drain (default: ./rke2.kubeconfig).
  WORKER_DRAIN_TIMEOUT Timeout passed to kubectl drain for worker nodes (default: 5m).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-images) DELETE_IMAGES=false; shift ;;
    --keep-networks) DELETE_NETWORKS=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }
}

log() {
  local timestamp
  timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  printf '[%s] %s\n' "${timestamp}" "$*"
}

delete_manifest_list() {
  local kind="$1"; shift
  local manifests=("$@")
  local manifest
  for manifest in "${manifests[@]}"; do
    [[ -z "${manifest}" ]] && continue
    if [[ ! -f "${manifest}" ]]; then
      log "Skipping ${kind} manifest ${manifest} (file not found)."
      continue
    fi
    log "Deleting ${kind} defined in ${manifest}."
    kubectl delete -f "${manifest}" --ignore-not-found >/dev/null 2>&1 || true
  done
}

guest_kubectl() {
  if [[ ! -f "${GUEST_KUBECONFIG}" ]]; then
    log "Guest kubeconfig ${GUEST_KUBECONFIG} not found; skipping guest cluster command: $*"
    return 1
  fi
  KUBECONFIG="${GUEST_KUBECONFIG}" kubectl "$@"
}

load_release_shape() {
  local values_json
  if ! values_json="$(helm -n "${NAMESPACE}" get values "${RELEASE}" -o json 2>/dev/null)"; then
    log "Unable to read Helm values for ${RELEASE}; falling back to defaults."
    return
  fi
  local prefix cp wk
  prefix="$(echo "${values_json}" | jq -r '.vmNamePrefix // empty' 2>/dev/null || true)"
  cp="$(echo "${values_json}" | jq -r '.replicaCounts.controlPlane // 0' 2>/dev/null || true)"
  wk="$(echo "${values_json}" | jq -r '.replicaCounts.worker // 0' 2>/dev/null || true)"
  [[ -n "${prefix}" && "${prefix}" != "null" ]] && VM_NAME_PREFIX="${prefix}"
  [[ -n "${cp}" && "${cp}" != "null" ]] && CONTROL_PLANE_COUNT="${cp}"
  [[ -n "${wk}" && "${wk}" != "null" ]] && WORKER_COUNT="${wk}"
  log "Derived cluster shape: prefix=${VM_NAME_PREFIX}, controlPlanes=${CONTROL_PLANE_COUNT}, workers=${WORKER_COUNT}."
}

cordon_drain_delete_workers() {
  if [[ "${WORKER_COUNT}" -le 0 ]]; then
    log "No worker nodes to cordon/drain based on Helm values."
    return
  fi
  if [[ ! -f "${GUEST_KUBECONFIG}" ]]; then
    log "Guest kubeconfig ${GUEST_KUBECONFIG} missing; skipping worker cordon/drain/delete."
    return
  fi
  log "Cordon/drain/delete for ${WORKER_COUNT} worker nodes via ${GUEST_KUBECONFIG}."
  local i node
  for ((i=1; i<=WORKER_COUNT; i++)); do
    node="${VM_NAME_PREFIX}-wk-${i}"
    if ! guest_kubectl get node "${node}" >/dev/null 2>&1; then
      log "Worker node ${node} not found in guest cluster; skipping."
      continue
    fi
    guest_kubectl cordon "${node}" >/dev/null 2>&1 || log "Cordon failed for ${node}; continuing."
    guest_kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout="${WORKER_DRAIN_TIMEOUT}" >/dev/null 2>&1 || log "Drain failed for ${node}; continuing to delete node."
    guest_kubectl delete node "${node}" --ignore-not-found >/dev/null 2>&1 || true
  done
}

delete_worker_pvcs() {
  log "Deleting all PVCs in namespace ${NAMESPACE} (full cleanup)."
  kubectl -n "${NAMESPACE}" delete pvc --all --ignore-not-found >/dev/null 2>&1 || true
}

require_bin helm
require_bin kubectl
require_bin jq

log "Starting cleanup for release ${RELEASE} in namespace ${NAMESPACE}."

load_release_shape
cordon_drain_delete_workers

if helm -n "${NAMESPACE}" status "${RELEASE}" >/dev/null 2>&1; then
  log "Uninstalling Helm release ${RELEASE}."
  helm uninstall "${RELEASE}" -n "${NAMESPACE}"
else
  log "Helm release ${RELEASE} not found; skipping uninstall."
fi

delete_worker_pvcs

log "Deleting bootstrap job artifacts (if present)."
kubectl -n "${NAMESPACE}" delete job rke2-bootstrap --ignore-not-found >/dev/null 2>&1 || true
kubectl delete -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-job.yaml" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-rbac.yaml" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete -f "${REPO_ROOT}/manifests/bootstrap/ssh-key-secret.yaml" --ignore-not-found >/dev/null 2>&1 || true

log "Removing Harvester CCM RBAC/service account."
kubectl delete clusterrolebinding rke2-cloud-provider-binding --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" delete serviceaccount rke2-mgmt-cloud-provider --ignore-not-found >/dev/null 2>&1 || true

if $DELETE_NETWORKS; then
  delete_manifest_list "network resources" "${NETWORK_MANIFESTS[@]}"
else
  log "Skipping network manifest deletion (per flag)."
fi

if $DELETE_IMAGES; then
  delete_manifest_list "VirtualMachineImage resources" "${IMAGE_MANIFESTS[@]}"
else
  log "Skipping VirtualMachineImage deletion (per flag)."
fi

log "Deleting namespace ${NAMESPACE}."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

log "Cleanup complete."
