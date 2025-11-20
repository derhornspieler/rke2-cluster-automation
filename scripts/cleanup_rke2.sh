#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${HELM_RELEASE:-rke2}"
NAMESPACE="${HARVESTER_NAMESPACE:-rke2}"
DELETE_IMAGES=false
DELETE_NETWORKS=false

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
  HARVESTER_NAMESPACE Guest-cluster namespace (default: rke2).
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

require_bin helm
require_bin kubectl

log "Starting cleanup for release ${RELEASE} in namespace ${NAMESPACE}."

if helm -n "${NAMESPACE}" status "${RELEASE}" >/dev/null 2>&1; then
  log "Uninstalling Helm release ${RELEASE}."
  helm uninstall "${RELEASE}" -n "${NAMESPACE}"
else
  log "Helm release ${RELEASE} not found; skipping uninstall."
fi

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
