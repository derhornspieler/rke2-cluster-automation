#!/usr/bin/env bash
set -euo pipefail

NS="rke2"
OUTDIR="rke2-debug-$(date +%Y%m%d%H%M%S)"
mkdir -p "$OUTDIR"

echo "Collecting PVC and DataVolume summaries..."
kubectl -n "$NS" get pvc -o wide > "$OUTDIR/pvc.txt"
kubectl -n "$NS" get dv -o wide > "$OUTDIR/datavolumes.txt"

echo "Describing each DataVolume..."
kubectl -n "$NS" get dv -o name | while read -r dv; do
  kubectl -n "$NS" describe "$dv" > "$OUTDIR/${dv//\//_}.describe.txt"
done

echo "Describing each PVC..."
kubectl -n "$NS" get pvc -o name | while read -r pvc; do
  kubectl -n "$NS" describe "$pvc" > "$OUTDIR/${pvc//\//_}.describe.txt"
done

echo "Recording events for namespace $NS..."
kubectl get events -n "$NS" --sort-by=.lastTimestamp > "$OUTDIR/events.txt"

echo "Collecting Longhorn volume status..."
kubectl -n longhorn-system get volumes > "$OUTDIR/longhorn-volumes.txt"
kubectl -n longhorn-system get volumes -o name | grep pvc- | while read -r vol; do
  kubectl -n longhorn-system describe "$vol" > "$OUTDIR/${vol//\//_}.describe.txt"
done

echo "Debug bundle saved under $OUTDIR/"

