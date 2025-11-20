#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${HELM_RELEASE:-rke2}"
NAMESPACE="${HARVESTER_NAMESPACE:-rke2}"
VALUES_FILE="${VALUES_FILE:-${REPO_ROOT}/custom_values.yaml}"
RKE2_KUBECONFIG="${RKE2_KUBECONFIG:-${REPO_ROOT}/rke2.kubeconfig}"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"
RUN_ADDON=true
SKIP_PREREQS=false
SKIP_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage: scripts/deploy_rke2.sh [options]

Options:
  --skip-prereqs     Skip Harvester prerequisite objects (namespace, images, SA/RBAC, networks).
  --skip-addon       Skip running generate_addon.sh for the Harvester CCM.
  --skip-bootstrap   Skip the kubeconfig bootstrap job/secret retrieval.
  -h, --help         Show this help and exit.

Environment variables:
  HELM_RELEASE        Override the Helm release name (default: rke2).
  HARVESTER_NAMESPACE Target namespace for the guest cluster (default: rke2).
  VALUES_FILE         Path to the Helm values file (default: custom_values.yaml).
  RKE2_KUBECONFIG     Where to write the extracted kubeconfig (default: ./rke2.kubeconfig).
  WAIT_SECONDS        Timeout (seconds) for VM readiness and bootstrap job (default: 1800).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prereqs) SKIP_PREREQS=true; shift ;;
    --skip-addon) RUN_ADDON=false; shift ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }
}

log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"
}

run_prereqs() {
  $SKIP_PREREQS && { log "Skipping prerequisite objects."; return; }
  log "Ensuring prerequisites exist on the Harvester management cluster (namespace: ${NAMESPACE})."
  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
  kubectl apply -f "${REPO_ROOT}/manifests/image/ubuntu.yaml"
  kubectl apply -f "${REPO_ROOT}/manifests/image/rocky9.yaml"
  kubectl apply -f "${REPO_ROOT}/manifests/network/networks.yaml"
  kubectl apply -f "${REPO_ROOT}/manifests/network/vmnet-vlan2003-ippool.yaml"
  kubectl -n "${NAMESPACE}" create serviceaccount rke2-mgmt-cloud-provider \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create clusterrolebinding rke2-cloud-provider-binding \
    --clusterrole=cluster-admin \
    --serviceaccount="${NAMESPACE}:rke2-mgmt-cloud-provider" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${REPO_ROOT}/manifests/bootstrap/ssh-key-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-rbac.yaml"
  if $RUN_ADDON; then
    log "Re-generating Harvester CCM addon kubeconfig."
    "${REPO_ROOT}/generate_addon.sh" rke2-mgmt-cloud-provider "${NAMESPACE}" | tee "${REPO_ROOT}/tmp/ccm-addon.out"
    log "Harvester CCM addon output saved to tmp/ccm-addon.out (remember to sync cloudProvider.cloudConfig)."
  fi
}

deploy_chart() {
  log "Deploying/Upgrading Helm release ${RELEASE} in namespace ${NAMESPACE}."
  helm upgrade --install "${RELEASE}" "${REPO_ROOT}/charts/rke2-harvester" \
    -n "${NAMESPACE}" -f "${VALUES_FILE}"
}

wait_for_vms() {
  log "Waiting for guest VMs (VirtualMachineInstances) to reach Running state."
  local start
  start=$(date +%s)
  while true; do
    if kubectl -n "${NAMESPACE}" get vmi >/dev/null 2>&1; then
      if kubectl -n "${NAMESPACE}" get vmi -o json | jq -e '
        (.items | length > 0) and
        (map(.status.phase == "Running") | all)' >/dev/null; then
        kubectl -n "${NAMESPACE}" get vmi -o wide
        break
      fi
    fi
    if (( $(date +%s) - start > WAIT_SECONDS )); then
      log "Timed out waiting for VMIs to become Running."
      exit 1
    fi
    sleep 10
  done
}

run_bootstrap_job() {
  $SKIP_BOOTSTRAP && { log "Skipping kubeconfig bootstrap job."; return; }
  log "Running bootstrap job to extract guest kubeconfig."
  kubectl -n "${NAMESPACE}" delete job rke2-bootstrap --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-job.yaml"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete job/rke2-bootstrap --timeout="${WAIT_SECONDS}s"
  kubectl -n "${NAMESPACE}" get secret rke2-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > "${RKE2_KUBECONFIG}"
  chmod 600 "${RKE2_KUBECONFIG}"
  log "Kubeconfig written to ${RKE2_KUBECONFIG}"
  kubectl delete -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-job.yaml"
}

require_bin helm
require_bin kubectl
require_bin jq

run_prereqs
deploy_chart
wait_for_vms
run_bootstrap_job

log "Deployment workflow finished. Export KUBECONFIG=${RKE2_KUBECONFIG} to interact with the guest cluster."
