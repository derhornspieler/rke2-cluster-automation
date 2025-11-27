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
HARVESTER_CHART_REPO="${HARVESTER_CHART_REPO:-https://charts.harvesterhci.io}"
HARVESTER_CSI_RELEASE="${HARVESTER_CSI_RELEASE:-harvester-csi-driver}"
HARVESTER_CSI_CHART="${HARVESTER_CSI_CHART:-harvester/harvester-csi-driver}"
HARVESTER_CSI_CHART_VERSION="${HARVESTER_CSI_CHART_VERSION:-}"
HARVESTER_CSI_NAMESPACE="${HARVESTER_CSI_NAMESPACE:-kube-system}"
HARVESTER_CSI_SECRET_NAME="${HARVESTER_CSI_SECRET_NAME:-harvester-cloud-config}"
HARVESTER_CSI_MANIFEST="${HARVESTER_CSI_MANIFEST:-${REPO_ROOT}/manifests/csi/harvester-csi-driver.yaml}"
HARVESTER_CSI_HELM_USE="${HARVESTER_CSI_HELM_USE:-true}"
HARVESTER_KUBEVIP_DS_ENABLED="${HARVESTER_KUBEVIP_DS_ENABLED:-true}"
CSI_CLOUD_CONFIG_FILE="${CSI_CLOUD_CONFIG_FILE:-}"
CSI_SMOKE_TEST="${CSI_SMOKE_TEST:-true}"
ADDON_CLOUD_CONFIG=""
HELM_EXTRA_VALUES=()
BOOTSTRAP_SSH_KEY="${BOOTSTRAP_SSH_KEY:-${TMP_DIR}/bootstrap_id_ed25519}"
GUEST_DRAIN_TIMEOUT="${GUEST_DRAIN_TIMEOUT:-5m}"
DESIRED_SHAPE_JSON=""
CURRENT_SHAPE_JSON=""
KUBEVIP_ADDRESS=""
KUBEVIP_INTERFACE=""

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
  --skip-bootstrap   Skip the kubeconfig bootstrap job/secret retrieval and guest API wait.
  -h, --help         Show this help and exit.

Environment variables:
  HELM_RELEASE        Override the Helm release name (default: rke2).
  HARVESTER_NAMESPACE Target namespace for the guest cluster (default: rke2).
  VALUES_FILE         Path to the Helm values file (default: custom_values.yaml).
  RKE2_KUBECONFIG     Where to write the extracted kubeconfig (default: ./rke2.kubeconfig).
  API_ENDPOINT        Override API server endpoint for the exported kubeconfig (default: kubeVip.address from Helm values).
  WAIT_SECONDS        Timeout (seconds) for VM readiness and bootstrap job (default: 1800).
  GUEST_DRAIN_TIMEOUT Timeout passed to kubectl drain when downsizing workers (default: 5m).
  CSI_CLOUD_CONFIG_FILE Override path to Harvester cloud-config for CSI secret (defaults to generated addon config).
  HARVESTER_CSI_CHART  Helm chart reference for Harvester CSI (default: harvester/harvester-csi-driver).
  HARVESTER_CSI_CHART_VERSION Optional chart version for CSI install.
  HARVESTER_CSI_MANIFEST Path to a local CSI manifest to apply instead of using the upstream chart (default: manifests/csi/harvester-csi-driver.yaml).
  CSI_SMOKE_TEST      Set to false to skip the PVC/Pod CSI smoke test (default: true).
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
  DESIRED_SHAPE_JSON="$(
    python3 - "$file" <<'PY' 2>/dev/null
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
  )"
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

# Best-effort read of a field from the values file.
read_values_field() {
  local field="$1"
  python3 - "$field" "${VALUES_FILE}" <<'PY' 2>/dev/null
import sys, re

field = sys.argv[1]
path = sys.argv[2]

def print_value(val):
    if val is None:
        return
    if isinstance(val, (int, float, bool)):
        print(val)
    elif isinstance(val, str):
        print(val)

try:
    import yaml  # type: ignore
    data = yaml.safe_load(open(path))
    cur = data
    for part in field.split('.'):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            cur = None
            break
    print_value(cur)
except Exception:
    # Fallback: best-effort regex scan for "key: value" when PyYAML isn't available.
    try:
        text = open(path).read()
    except Exception:
        sys.exit(0)
    key = field.split('.')[-1]
    pattern = re.compile(rf'^{re.escape(key)}\s*:\s*(.+)$', re.MULTILINE)
    m = pattern.search(text)
    if m:
        val = m.group(1).strip().strip('"\'')
        print(val)
PY
}

# Return first control-plane VMI IP (empty if none yet).
get_control_plane_ip() {
  kubectl -n "${NAMESPACE}" get vmi -l app.kubernetes.io/component=controlplane \
    -o jsonpath='{range .items[?(@.status.interfaces[0].ipAddress!="")]}{.status.interfaces[0].ipAddress}{"\n"}{end}' | head -n1
}

disable_kubevip_daemonset() {
  if [[ "${HARVESTER_KUBEVIP_DS_ENABLED}" == "true" ]]; then
    log "Keeping kube-vip daemonset enabled (HARVESTER_KUBEVIP_DS_ENABLED=true)."
    local vip addr iface
    addr="${KUBEVIP_ADDRESS:-$(read_values_field kubeVip.address)}"
    iface="${KUBEVIP_INTERFACE:-$(read_values_field kubeVip.interface)}"
    # Force static kube-vip off in our chart.
    local overlay="${TMP_DIR}/kubevip-disable-static.values.yaml"
    mkdir -p "${TMP_DIR}"
    cat <<EOF > "${overlay}"
kubeVip:
  enabled: false
EOF
    HELM_EXTRA_VALUES+=("${overlay}")
    # Ensure HelmChartConfig enables kube-vip and passes VIP/interface if provided.
    cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: harvester-cloud-provider
  namespace: kube-system
spec:
  valuesContent: |
    kube-vip:
      enabled: true
      env:
        vip_address: ${addr:-""}
        vip_interface: ${iface:-""}
        vip_arp: "true"
        lb_enable: "true"
        lb_port: "6443"
        vip_cidr: "32"
        cp_enable: "false"
        svc_enable: "true"
        vip_leaderelection: "true"
EOF
    return
  fi
  log "Disabling kube-vip daemonset from harvester-cloud-provider (keeping static kube-vip)."
  cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: harvester-cloud-provider
  namespace: kube-system
spec:
  valuesContent: |
    kube-vip:
      enabled: false
EOF
  kubectl -n kube-system delete ds kube-vip --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete pod -l app.kubernetes.io/name=kube-vip --ignore-not-found >/dev/null 2>&1 || true
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
  local cp_ip status_out
  log "Waiting for cloud-init to finish on control-plane VM."
  while true; do
    cp_ip="$(get_control_plane_ip)"
    [[ -n "${cp_ip}" ]] && break
    sleep 5
  done
  status_out="$(ssh -i "${BOOTSTRAP_SSH_KEY}" -o StrictHostKeyChecking=no -o IdentitiesOnly=yes \
    rocky@"${cp_ip}" 'sudo cloud-init status --wait || true; sudo cloud-init status --long' 2>/dev/null || true)"
  if grep -q "status: error" <<<"${status_out}"; then
    log "cloud-init reported failure on ${cp_ip}; recent log output follows:" >&2
    ssh -i "${BOOTSTRAP_SSH_KEY}" -o StrictHostKeyChecking=no -o IdentitiesOnly=yes \
      rocky@"${cp_ip}" 'sudo tail -n 100 /var/log/cloud-init-output.log' >&2 || true
    exit 1
  fi
  log "cloud-init completed on ${cp_ip}."
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

validate_guest_workers() {
  [[ ! -f "${RKE2_KUBECONFIG}" ]] && { log "Guest kubeconfig ${RKE2_KUBECONFIG} not found; skipping worker validation."; return; }

  local desired_workers prefix
  desired_workers="$(shape_value "${DESIRED_SHAPE_JSON}" '.worker')"
  prefix="$(shape_value "${DESIRED_SHAPE_JSON}" '.vmNamePrefix')"
  [[ -z "${prefix}" || "${prefix}" == "null" ]] && prefix="${RELEASE}"

  if [[ -z "${desired_workers}" || "${desired_workers}" == "null" ]]; then
    log "Desired worker count unknown; skipping worker validation."
    return
  fi

  local nodes_json
  if ! nodes_json=$(KUBECONFIG="${RKE2_KUBECONFIG}" kubectl --request-timeout=15s get nodes -o json 2>/dev/null); then
    log "Unable to query guest nodes with kubeconfig ${RKE2_KUBECONFIG}; skipping worker validation."
    return
  fi

  local summary actual ready names
  summary=$(jq -r --arg prefix "${prefix}-wk-" '
    [ .items[]? | select(.metadata.name | startswith($prefix)) ] as $nodes
    | [
        ($nodes | length),
        ($nodes | map(select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))) | length),
        ($nodes | map(.metadata.name) | sort | join(","))
      ] | @tsv
  ' <<<"${nodes_json}")
  IFS=$'\t' read -r actual ready names <<<"${summary}"

  if (( actual == desired_workers )); then
    log "Worker validation: ${actual}/${desired_workers} nodes matching prefix ${prefix}-wk- present (Ready: ${ready})."
  else
    log "WARNING: Worker validation mismatch for prefix ${prefix}-wk- (expected ${desired_workers}, found ${actual}; Ready: ${ready}). Nodes: ${names:-<none>}."
  fi
}

install_harvester_csi() {
  $SKIP_BOOTSTRAP && { log "Skipping Harvester CSI install because bootstrap was skipped (guest kubeconfig not refreshed)."; return; }
  [[ ! -f "${RKE2_KUBECONFIG}" ]] && { log "Guest kubeconfig ${RKE2_KUBECONFIG} not found; cannot install Harvester CSI."; return; }

  local cfg="${CSI_CLOUD_CONFIG_FILE:-${ADDON_CLOUD_CONFIG:-}}"
  if [[ -z "${cfg}" || ! -f "${cfg}" ]]; then
    log "Harvester cloud-config not found (looked for ${cfg:-<unset>}); set CSI_CLOUD_CONFIG_FILE to a kubeconfig for the Harvester management cluster."
    return
  fi

  log "Ensuring CSI snapshot CRDs are present."
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
    -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
    -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml >/dev/null

  log "Creating/Updating CSI cloud-config secret ${HARVESTER_CSI_SECRET_NAME} in namespace ${HARVESTER_CSI_NAMESPACE}."
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" create secret generic "${HARVESTER_CSI_SECRET_NAME}" \
    --from-file=cloud-provider-config="${cfg}" --dry-run=client -o yaml | \
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl apply -f -

  # Clean up any manual CSI resources to avoid helm ownership conflicts.
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" delete deploy csi-controller --ignore-not-found >/dev/null 2>&1 || true
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" delete ds harvester-csi-plugin --ignore-not-found >/dev/null 2>&1 || true
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl delete sc harvester --ignore-not-found >/dev/null 2>&1 || true
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl delete csidriver driver.harvesterhci.io --ignore-not-found >/dev/null 2>&1 || true

  if [[ "${HARVESTER_CSI_HELM_USE}" == "true" ]]; then
    cat <<EOF | KUBECONFIG="${RKE2_KUBECONFIG}" kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: harvester-csi-driver
  namespace: kube-system
spec:
  valuesContent: |
    cloudConfig:
      secretName: ${HARVESTER_CSI_SECRET_NAME}
EOF
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" delete job -l app=helm,name=harvester-csi-driver --ignore-not-found >/dev/null 2>&1 || true
    log "Relying on helm-controller/HelmChart to install harvester-csi-driver (helm path)."
    # Post-patch controller pods to run as root (minimal change vs full privileged) so they can access the host-mounted /csi socket.
    local waited=0
    until KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" get deploy harvester-csi-driver-controllers >/dev/null 2>&1; do
      sleep 5
      waited=$((waited+5))
      if (( waited >= 180 )); then
        log "Timed out waiting for harvester-csi-driver-controllers deployment to appear; skipping securityContext patch."
        return
      fi
    done
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n "${HARVESTER_CSI_NAMESPACE}" patch deploy harvester-csi-driver-controllers --type='json' -p='[
      {"op":"add","path":"/spec/template/spec/securityContext","value":{"runAsUser":0,"runAsGroup":0,"fsGroup":0}},
      {"op":"add","path":"/spec/template/spec/containers/0/securityContext","value":{"runAsUser":0,"runAsGroup":0,"privileged":true}},
      {"op":"add","path":"/spec/template/spec/containers/1/securityContext","value":{"runAsUser":0,"runAsGroup":0,"privileged":true}},
      {"op":"add","path":"/spec/template/spec/containers/2/securityContext","value":{"runAsUser":0,"runAsGroup":0,"privileged":true}},
      {"op":"add","path":"/spec/template/spec/containers/3/securityContext","value":{"runAsUser":0,"runAsGroup":0,"privileged":true}}
    ]' || true
  else
    log "HARVESTER_CSI_HELM_USE=false; helm-controller path skipped."
  fi
}

patch_kubevip_daemonset() {
  [[ ! -f "${RKE2_KUBECONFIG}" ]] && { log "Guest kubeconfig ${RKE2_KUBECONFIG} not found; cannot patch kube-vip."; return; }
  local addr iface cidr
  addr="${KUBEVIP_ADDRESS:-$(read_values_field kubeVip.address)}"
  iface="${KUBEVIP_INTERFACE:-$(read_values_field kubeVip.interface)}"
  cidr="$(read_values_field kubeVip.cidr)"
  [[ -z "${cidr}" || "${cidr}" == "null" ]] && cidr="$(read_values_field kubeVip.prefix)"
  [[ -z "${cidr}" || "${cidr}" == "null" ]] && cidr="24"
  if [[ -z "${addr}" || -z "${iface}" ]]; then
    log "kube-vip address/interface not found; skipping kube-vip DaemonSet patch."
    return
  fi

  log "Patching kube-vip DaemonSet to set sysctls and ensure VIP ${addr}/${cidr} on ${iface}."
  local waited=0
  until KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n kube-system get ds kube-vip >/dev/null 2>&1; do
    sleep 5; waited=$((waited+5))
    if (( waited >= 120 )); then
      log "Timed out waiting for kube-vip DaemonSet to appear; skipping patch."
      return
    fi
  done

  local payload
  payload="$(cat <<EOF
[
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers",
    "value": [
      {
        "name": "sysctl-promote-secondaries",
        "image": "busybox:1.36",
        "securityContext": { "privileged": true },
        "command": [
          "sh","-c",
          "sysctl -w net.ipv4.conf.all.promote_secondaries=1 net.ipv4.conf.${iface}.promote_secondaries=1 net.ipv4.conf.all.accept_local=1 net.ipv4.conf.${iface}.accept_local=1"
        ]
      }
    ]
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/lifecycle",
    "value": {
      "postStart": {
        "exec": {
          "command": ["sh","-c","ip addr add ${addr}/${cidr} dev ${iface} 2>/dev/null || true"]
        }
      }
    }
  }
]
EOF
)"
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl -n kube-system patch ds kube-vip --type=json -p "${payload}" >/dev/null 2>&1 || log "kube-vip patch failed; continuing."
}

smoke_test_csi() {
  [[ "${CSI_SMOKE_TEST}" == "false" ]] && { log "Skipping CSI smoke test (CSI_SMOKE_TEST=${CSI_SMOKE_TEST})."; return; }
  [[ ! -f "${RKE2_KUBECONFIG}" ]] && { log "Guest kubeconfig ${RKE2_KUBECONFIG} not found; skipping CSI smoke test."; return; }

  local name="harvester-csi-smoke-$(date +%s)"
  local pvc="${name}"
  local pod="${name}"
  local pvc_timeout="${CSI_SMOKE_PVC_TIMEOUT:-120s}"
  local pod_timeout="${CSI_SMOKE_POD_TIMEOUT:-120s}"
  log "Starting CSI smoke test with PVC/Pod ${name} (PVC timeout ${pvc_timeout}, Pod timeout ${pod_timeout})."
  cat <<EOF | KUBECONFIG="${RKE2_KUBECONFIG}" kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: harvester
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["/bin/sh","-c","echo smoke-ok > /data/hello && sleep 300"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${pvc}
EOF
  local rc=0
  if ! KUBECONFIG="${RKE2_KUBECONFIG}" kubectl wait --for=condition=Bound pvc/"${pvc}" --timeout="${pvc_timeout}"; then
    log "CSI smoke test PVC did not bind within timeout ${pvc_timeout}; checking status."
    if ! KUBECONFIG="${RKE2_KUBECONFIG}" kubectl get pvc "${pvc}" -o jsonpath='{.status.phase}' | grep -q "^Bound$"; then
      rc=1
    fi
  fi
  if (( rc == 0 )) && ! KUBECONFIG="${RKE2_KUBECONFIG}" kubectl wait --for=condition=Ready pod/"${pod}" --timeout="${pod_timeout}"; then
    log "CSI smoke test pod did not become Ready within timeout ${pod_timeout}."
    rc=1
  fi
  if (( rc == 0 )) && ! KUBECONFIG="${RKE2_KUBECONFIG}" kubectl exec "${pod}" -- cat /data/hello | grep -q "smoke-ok"; then
    log "CSI smoke test content verification failed."
    rc=1
  fi

  if (( rc != 0 )); then
    log "CSI smoke test failed; dumping describe for PVC/Pod."
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl describe pvc "${pvc}" || true
    KUBECONFIG="${RKE2_KUBECONFIG}" kubectl describe pod "${pod}" || true
  fi
  KUBECONFIG="${RKE2_KUBECONFIG}" kubectl delete pod "${pod}" pvc "${pvc}" --ignore-not-found >/dev/null 2>&1 || true
  if (( rc == 0 )); then
    log "CSI smoke test succeeded."
  else
    return 1
  fi
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
    ADDON_CLOUD_CONFIG="${addon_cfg_insecure}"
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
  # Normalize context name/current-context to \"rke2\" for easier merging/flattening.
  if kubectl --kubeconfig="${RKE2_KUBECONFIG}" config get-contexts default >/dev/null 2>&1; then
    kubectl --kubeconfig="${RKE2_KUBECONFIG}" config rename-context default rke2 >/dev/null 2>&1 || true
  fi
  kubectl --kubeconfig="${RKE2_KUBECONFIG}" config use-context rke2 >/dev/null 2>&1 || true
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
disable_kubevip_daemonset
deploy_chart
wait_for_vms
run_bootstrap_job
if $SKIP_BOOTSTRAP; then
  log "Skipping guest API wait because bootstrap was skipped."
else
  wait_for_guest_api
  install_harvester_csi
  patch_kubevip_daemonset
  smoke_test_csi || true
fi
validate_guest_workers

log "Deployment workflow finished. Export KUBECONFIG=${RKE2_KUBECONFIG} to interact with the guest cluster."
