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
TMP_DIR="${REPO_ROOT}/tmp"
HELM_EXTRA_VALUES=()
BOOTSTRAP_SSH_KEY="${BOOTSTRAP_SSH_KEY:-${TMP_DIR}/bootstrap_id_ed25519}"
GUEST_DRAIN_TIMEOUT="${GUEST_DRAIN_TIMEOUT:-5m}"
DESIRED_SHAPE_JSON=""
CURRENT_SHAPE_JSON=""

IMAGE_MANIFESTS=(
  "${REPO_ROOT}/manifests/image/ubuntu.yaml"
  "${REPO_ROOT}/manifests/image/rocky9.yaml"
)

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
  API_ENDPOINT        Override API server endpoint for the exported kubeconfig (default: kubeVip.address from Helm values).
  WAIT_SECONDS        Timeout (seconds) for VM readiness and bootstrap job (default: 1800).
  GUEST_DRAIN_TIMEOUT Timeout passed to kubectl drain when downsizing workers (default: 5m).
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
  local timestamp
  timestamp="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  printf '[%s] %s\n' "${timestamp}" "$*"
}

# Extract controlPlane/worker counts and vmNamePrefix from values file (best effort).
load_desired_shape() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    log "Values file ${file} not found; skipping desired shape parsing."
    DESIRED_SHAPE_JSON='{}'
    return
  fi
  DESIRED_SHAPE_JSON="$(python3 - "$file" <<'PY' 2>/dev/null || true)"
import json, re, sys
from pathlib import Path
try:
    import yaml
except ImportError:
    yaml = None

path = Path(sys.argv[1])
if not path.exists():
    print("{}")
    sys.exit(0)
text = path.read_text()

def regex_find(pattern):
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else None

if yaml is None:
    cp = regex_find(r"controlPlane:\s*([0-9]+)")
    wk = regex_find(r"worker:\s*([0-9]+)")
    prefix = regex_find(r"vmNamePrefix:\s*([A-Za-z0-9._:-]+)")
    out = {
        "controlPlane": int(cp) if cp else None,
        "worker": int(wk) if wk else None,
        "vmNamePrefix": prefix,
    }
    print(json.dumps(out))
    sys.exit(0)

data = yaml.safe_load(text) or {}
def deep_get(d, path):
    cur = d
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur

out = {
    "controlPlane": deep_get(data, ["replicaCounts", "controlPlane"]),
    "worker": deep_get(data, ["replicaCounts", "worker"]),
    "vmNamePrefix": data.get("vmNamePrefix"),
}
print(json.dumps(out))
PY
)
}

# Load current cluster shape from the installed release (if present).
load_current_shape() {
  if ! CURRENT_SHAPE_JSON="$(helm -n "${NAMESPACE}" get values "${RELEASE}" -o json 2>/dev/null)"; then
    CURRENT_SHAPE_JSON='{}'
  fi
}

shape_value() {
  local json="$1" path="$2"
  jq -r "${path} // empty" <<<"${json}" 2>/dev/null || true
}

pre_drain_workers_if_shrinking() {
  local current_workers desired_workers prefix node
  current_workers="$(shape_value "${CURRENT_SHAPE_JSON}" '.replicaCounts.worker')"
  desired_workers="$(shape_value "${DESIRED_SHAPE_JSON}" '.worker')"
  prefix="$(shape_value "${CURRENT_SHAPE_JSON}" '.vmNamePrefix')"
  [[ -z "${prefix}" || "${prefix}" == "null" ]] && prefix="${RELEASE}"
  if [[ -z "${current_workers}" || -z "${desired_workers}" ]]; then
    log "Unable to determine worker delta (current=${current_workers:-unknown}, desired=${desired_workers:-unknown}); skipping pre-drain."
    return
  fi
  if (( desired_workers >= current_workers )); then
    log "Worker count not decreasing (current=${current_workers}, desired=${desired_workers}); no pre-drain needed."
    return
  fi
  if [[ ! -f "${RKE2_KUBECONFIG}" ]]; then
    log "Guest kubeconfig ${RKE2_KUBECONFIG} missing; cannot cordon/drain workers before resize."
    return
  fi
  log "Worker count decreasing from ${current_workers} to ${desired_workers}; cordon/drain/delete nodes ${prefix}-wk-<n> above desired."
  local i
  for ((i = desired_workers + 1; i <= current_workers; i++)); do
    node="${prefix}-wk-${i}"
    if ! KUBECONFIG="${RKE2_KUBECONFIG}" kubectl get node "${node}" >/dev/null 2>&1; then
      log "Node ${node} not found; skipping."
      continue
    fi
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl cordon "${node}" >/dev/null 2>&1 || log "Cordon failed for ${node}; continuing."
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout="${GUEST_DRAIN_TIMEOUT}" >/dev/null 2>&1 || log "Drain failed for ${node}; continuing to delete node."
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl delete node "${node}" --ignore-not-found >/dev/null 2>&1 || true
  done
}

# Enforce control-plane >=3 preflight to avoid failed upgrades later.
precheck_control_plane_minimum() {
  local desired_cp
  desired_cp="$(shape_value "${DESIRED_SHAPE_JSON}" '.controlPlane')"
  if [[ -z "${desired_cp}" ]]; then
    log "Desired control-plane count unknown (could not parse values); chart will enforce >=3."
    return
  fi
  if (( desired_cp < 3 )); then
    log "ERROR: control-plane count ${desired_cp} < 3 is not supported; aborting before Helm upgrade."
    exit 1
  fi
}

# Return the desired API endpoint for the guest cluster. Preference order:
# 1) API_ENDPOINT environment variable (manual override)
# 2) kubeVip.address from the installed Helm release values
get_api_endpoint() {
  local override="${API_ENDPOINT:-}"
  if [[ -n "${override}" ]]; then
    printf '%s' "${override}"
    return
  fi
  helm -n "${NAMESPACE}" get values "${RELEASE}" -o json 2>/dev/null | \
    jq -r '.kubeVip.address // empty' || true
}

# Return first control-plane VMI IP (empty if none yet).
get_control_plane_ip() {
  kubectl -n "${NAMESPACE}" get vmi -l app.kubernetes.io/component=controlplane \
    -o jsonpath='{range .items[?(@.status.interfaces[0].ipAddress!="")]}{.status.interfaces[0].ipAddress}{"\n"}{end}' | head -n1
}

ensure_bootstrap_ssh_key() {
  mkdir -p "${TMP_DIR}"
  if [[ -f "${BOOTSTRAP_SSH_KEY}" ]]; then
    chmod 600 "${BOOTSTRAP_SSH_KEY}"
    return
  fi
  local key_b64
  if key_b64=$(kubectl -n "${NAMESPACE}" get secret rke2-bootstrap-sshkey -o jsonpath='{.data.id_ed25519}' 2>/dev/null); then
    if [[ -n "${key_b64}" ]]; then
      echo "${key_b64}" | base64 -d > "${BOOTSTRAP_SSH_KEY}"
      chmod 600 "${BOOTSTRAP_SSH_KEY}"
      return
    fi
  fi
  log "Unable to retrieve bootstrap SSH key from secret rke2-bootstrap-sshkey." >&2
  exit 1
}

# Wait for SSH on a control-plane IP before launching the bootstrap job.
wait_for_cp_ssh() {
  local start cp_ip last_log=0
  start=$(date +%s)
  log "Waiting for control-plane SSH to be reachable (pre-bootstrap)."
  while true; do
    cp_ip="$(get_control_plane_ip)"
    if [[ -n "${cp_ip}" ]] && nc -zvw3 "${cp_ip}" 22 >/dev/null 2>&1; then
      log "Control-plane SSH reachable at ${cp_ip}."
      break
    fi
    local now
    now=$(date +%s)
    if (( now - start > WAIT_SECONDS )); then
      log "Timed out waiting for control-plane SSH to become reachable." >&2
      exit 1
    fi
    if (( now - last_log >= 30 )); then
      log "Control-plane IP/SSH not ready yet; retrying..."
      last_log=${now}
    fi
    sleep 5
  done
}

wait_for_cloud_init() {
  ensure_bootstrap_ssh_key
  local start last_log=0 cp_ip
  start=$(date +%s)
  log "Waiting for cloud-init to finish on control-plane VM."
  while true; do
    cp_ip="$(get_control_plane_ip)"
    if [[ -z "${cp_ip}" ]]; then
      sleep 5
      continue
    fi
    if ssh -i "${BOOTSTRAP_SSH_KEY}" -o StrictHostKeyChecking=no -o IdentitiesOnly=yes \
      rocky@"${cp_ip}" 'sudo cloud-init status --wait && sudo grep -E "Cloud-init[: ]+v.*finished" /var/log/cloud-init-output.log' >/dev/null 2>&1; then
      log "cloud-init completed on ${cp_ip}."
      break
    fi
    local now
    now=$(date +%s)
    if (( now - start > WAIT_SECONDS )); then
      log "Timed out waiting for cloud-init to complete on ${cp_ip:-unknown}." >&2
      exit 1
    fi
    if (( now - last_log >= 30 )); then
      log "cloud-init not finished yet on ${cp_ip:-unknown}; retrying..."
      last_log=${now}
    fi
    sleep 10
  done
}

# Rewrite the kubeconfig server endpoint to the provided host/IP (keeps the scheme/port).
rewrite_kubeconfig_endpoint() {
  local kubeconfig="$1"
  local endpoint="$2"
  [[ -z "${endpoint}" ]] && return

  # Accept hostname/IP, host:port, or full https:// URL. Default port to 6443 if omitted.
  local new_url
  if [[ "${endpoint}" =~ ^https?:// ]]; then
    new_url="${endpoint}"
  elif [[ "${endpoint}" =~ :[0-9]+$ ]]; then
    new_url="https://${endpoint}"
  else
    new_url="https://${endpoint}:6443"
  fi

  perl -0pi -e 's#server: https?://[^\n]+#server: '"${new_url//\//\\/}"'#' "${kubeconfig}"
}

wait_for_guest_api() {
  [[ ! -f "${RKE2_KUBECONFIG}" ]] && { log "Guest kubeconfig ${RKE2_KUBECONFIG} not found; skipping API wait."; return; }
  local start last_log=0
  start=$(date +%s)
  log "Waiting for guest cluster API to become reachable using ${RKE2_KUBECONFIG}."
  while true; do
    if KUBECONFIG="${RKE2_KUBECONFIG}" kubectl --request-timeout=10s get nodes >/dev/null 2>&1; then
      KUBECONFIG="${RKE2_KUBECONFIG}" kubectl get nodes
      break
    fi
    local now
    now=$(date +%s)
    if (( now - start > WAIT_SECONDS )); then
      log "Timed out waiting for guest API to respond via kubeconfig ${RKE2_KUBECONFIG}." >&2
      exit 1
    fi
    if (( now - last_log >= 30 )); then
      log "Guest API not reachable yet; retrying..."
      last_log=${now}
    fi
    sleep 5
  done
}

wait_for_vm_images() {
  local images=("$@")
  ((${#images[@]} == 0)) && return

  local ref
  for ref in "${images[@]}"; do
    [[ -z "$ref" ]] && continue
    local namespace="${ref%%/*}"
    local name="${ref##*/}"
    namespace=${namespace:-default}
    local start last_progress="" last_log=0
    start=$(date +%s)
    log "Waiting for VirtualMachineImage ${namespace}/${name} to finish downloading."

    while true; do
      local json
      if ! json=$(kubectl -n "${namespace}" get virtualmachineimage "${name}" -o json 2>/dev/null); then
        log "VirtualMachineImage ${namespace}/${name} not found yet; waiting..."
        sleep 5
        continue
      fi

      local summary
      summary=$(jq -r '[any(.status.conditions[]?; .type=="Imported" and .status=="True"),
                        any(.status.conditions[]?; .type=="RetryLimitExceeded" and .status=="True"),
                        any(.status.conditions[]?; .type=="BackingImageMissing" and .status=="True"),
                        .status.progress // 0,
                        .status.failed // 0] | @tsv' <<<"${json}")
      local imported retryExceeded backingMissing progress failedCount
      IFS=$'\t' read -r imported retryExceeded backingMissing progress failedCount <<<"${summary}"

      if [[ "${retryExceeded}" == "true" ]]; then
        log "Image ${namespace}/${name} failed to import (RetryLimitExceeded condition set)." >&2
        exit 1
      fi
      if [[ "${backingMissing}" == "true" ]]; then
        log "Image ${namespace}/${name} reports BackingImageMissing; verify Harvester backing images/storage." >&2
        exit 1
      fi
      if [[ "${imported}" == "true" ]]; then
        log "Image ${namespace}/${name} is ready (progress ${progress}%, failed attempts ${failedCount})."
        break
      fi

      local now
      now=$(date +%s)
      if (( now - start > WAIT_SECONDS )); then
        log "Timed out waiting for image ${namespace}/${name} to finish downloading (last progress ${progress}%)." >&2
        exit 1
      fi
      if [[ "${progress}" != "${last_progress}" ]]; then
        log "Image ${namespace}/${name} import progress: ${progress}%"
        last_progress="${progress}"
        last_log=${now}
      elif (( now - last_log >= 60 )); then
        log "Image ${namespace}/${name} still importing (progress ${progress}%)."
        last_log=${now}
      fi
      sleep 10
    done
  done
}

run_prereqs() {
  $SKIP_PREREQS && { log "Skipping prerequisite objects."; return; }
  log "Ensuring prerequisites exist on the Harvester management cluster (namespace: ${NAMESPACE})."
  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
  local vm_images=()
  local manifest
  for manifest in "${IMAGE_MANIFESTS[@]}"; do
    if [[ ! -f "${manifest}" ]]; then
      log "Image manifest ${manifest} not found; skipping."
      continue
    fi
    local image_name image_namespace
    image_name=$(kubectl apply --dry-run=client -f "${manifest}" -o jsonpath='{.metadata.name}')
    image_namespace=$(kubectl apply --dry-run=client -f "${manifest}" -o jsonpath='{.metadata.namespace}')
    image_namespace=${image_namespace:-default}
    if kubectl -n "${image_namespace}" get virtualmachineimage "${image_name}" >/dev/null 2>&1; then
      log "VirtualMachineImage ${image_namespace}/${image_name} already exists; skipping apply."
    else
      kubectl apply -f "${manifest}"
    fi
    vm_images+=("${image_namespace}/${image_name}")
  done
  wait_for_vm_images "${vm_images[@]}"
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
    mkdir -p "${TMP_DIR}"
    log "Re-generating Harvester CCM addon kubeconfig."
    local addon_out="${TMP_DIR}/ccm-addon.out"
    "${REPO_ROOT}/generate_addon.sh" rke2-mgmt-cloud-provider "${NAMESPACE}" | tee "${addon_out}"
    local addon_cfg="${TMP_DIR}/ccm-addon.cloudconfig"
    awk '/^########## cloud config ############/{flag=1;next}/^########## cloud-init user data ############/{flag=0}flag' "${addon_out}" > "${addon_cfg}"
    local addon_cfg_insecure="${TMP_DIR}/ccm-addon.cloudconfig.insecure"
    # Strip CA data and force insecure-skip-tls-verify so CCM uses insecure option instead of embedded CA.
    awk '
      /certificate-authority-data:/ {next}
      {print}
      /^[[:space:]]*server:/ {print "    insecure-skip-tls-verify: true"}
    ' "${addon_cfg}" > "${addon_cfg_insecure}"
    local overlay="${TMP_DIR}/cloud-config.values.yaml"
    {
      echo "cloudProvider:"
      echo "  cloudConfig: |-"
      sed 's/^/    /' "${addon_cfg_insecure}"
    } > "${overlay}"
    HELM_EXTRA_VALUES+=("${overlay}")
    log "Harvester CCM addon output saved to ${addon_out}; cloud-config extracted to ${addon_cfg_insecure}; overlay values at ${overlay}."
  fi
}

deploy_chart() {
  log "Deploying/Upgrading Helm release ${RELEASE} in namespace ${NAMESPACE}."
  local args=(-n "${NAMESPACE}" -f "${VALUES_FILE}")
  if ((${#HELM_EXTRA_VALUES[@]} > 0)); then
    local f
    for f in "${HELM_EXTRA_VALUES[@]}"; do
      args+=(-f "$f")
    done
  fi
  helm upgrade --install "${RELEASE}" "${REPO_ROOT}/charts/rke2-harvester" "${args[@]}"
}

wait_for_vms() {
  log "Waiting for guest VMs (VirtualMachineInstances) to reach Running state with IPs."
  local start
  start=$(date +%s)
  while true; do
    if kubectl -n "${NAMESPACE}" get vmi >/dev/null 2>&1; then
      if kubectl -n "${NAMESPACE}" get vmi -o json | jq -e '
        .items
        | length > 0
        and all(
          .status.phase == "Running"
          and (.status.interfaces // [] | any(.ipAddress != ""))
        )' >/dev/null; then
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
  wait_for_cp_ssh
  wait_for_cloud_init
  log "Running bootstrap job to extract guest kubeconfig."
  kubectl -n "${NAMESPACE}" delete job rke2-bootstrap --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-job.yaml"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete job/rke2-bootstrap --timeout="${WAIT_SECONDS}s"
  kubectl -n "${NAMESPACE}" get secret rke2-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > "${RKE2_KUBECONFIG}"
  chmod 600 "${RKE2_KUBECONFIG}"
  local api_endpoint
  api_endpoint="$(get_api_endpoint)"
  if [[ -n "${api_endpoint}" ]]; then
    log "Setting kubeconfig server endpoint to ${api_endpoint}."
    rewrite_kubeconfig_endpoint "${RKE2_KUBECONFIG}" "${api_endpoint}"
    kubectl create secret generic rke2-kubeconfig \
      --from-file=kubeconfig="${RKE2_KUBECONFIG}" \
      -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  else
    log "No API endpoint override provided; kubeconfig server left unchanged."
  fi
  log "Kubeconfig written to ${RKE2_KUBECONFIG}"
  kubectl delete -f "${REPO_ROOT}/manifests/bootstrap/bootstrap-job.yaml"
}

require_bin helm
require_bin kubectl
require_bin jq

load_desired_shape "${VALUES_FILE}"
load_current_shape
precheck_control_plane_minimum
pre_drain_workers_if_shrinking

run_prereqs
deploy_chart
wait_for_vms
run_bootstrap_job
wait_for_guest_api

log "Deployment workflow finished. Export KUBECONFIG=${RKE2_KUBECONFIG} to interact with the guest cluster."
