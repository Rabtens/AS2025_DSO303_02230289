#!/usr/bin/env bash
# Lab 08 Step 15 - reach usms-gateway (type LoadBalancer) every way available.
# Reads the host ports k3d actually published instead of assuming 8081/8082,
# and falls back to port-forward when EXTERNAL-IP stays <pending>. Read-only.
# Usage: ./scripts/utilities/lab-08-lb-check.sh
set -uo pipefail

NS="${USMS_EKS_NAMESPACE:-usms}"
CLUSTER="${USMS_EKS_CLUSTER:-usms-eks-cluster}"
LB="k3d-${CLUSTER}-serverlb"

# Host port that k3d's load balancer maps to a given container port (80 / 443).
host_port() { docker port "$LB" "$1/tcp" 2>/dev/null | head -1 | awk -F: '{print $NF}'; }
P80=$(host_port 80)
P443=$(host_port 443)

echo "--- Lab 07 _lb_ports_ tag says: ${USMS_EKS_LB_PORTS:-8081,8082} ---"
echo "--- k3d actually publishes: port 80 -> ${P80:-none}, port 443 -> ${P443:-none} ---"
if [ "${P80:-}" != "8081" ] && ss -ltn 2>/dev/null | grep -q ':8081 '; then
  echo "    note: host port 8081 is held by another process (e.g. a local Apache), not the cluster"
fi
echo

echo "--- via the published host port for cluster port 80 (localhost:${P80:-?}) ---"
if [ -n "${P80:-}" ]; then
  curl -s --max-time 5 "http://localhost:$P80/" || echo "  (no answer)"
  echo "  (404 here = Traefik answering with no Ingress route yet; expected until Step 16)"
fi
echo

echo "--- via the published host port for cluster port 443 (localhost:${P443:-?}) ---"
if [ -n "${P443:-}" ]; then
  curl -s --max-time 5 "http://localhost:$P443/" || echo "  (no answer)"
fi
echo

echo "--- via the assigned EXTERNAL-IP, if there is one ---"
EXT=$(kubectl get svc usms-gateway -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
echo "EXTERNAL-IP = ${EXT:-none}"
if [ -n "$EXT" ]; then
  kubectl run usms-debug -n "$NS" --rm -i --restart=Never --image=busybox:1.36 -- \
    wget -qO- --timeout=5 "http://$EXT/" 2>/dev/null || echo "  (no answer from $EXT)"
else
  echo "  <pending>: k3s ServiceLB cannot bind port 80 (Traefik holds it) - legitimate on a local build"
  echo "--- fallback: kubectl port-forward svc/usms-gateway 18080:80 ---"
  kubectl port-forward -n "$NS" svc/usms-gateway 18080:80 >/dev/null 2>&1 &
  PF=$!
  sleep 3
  curl -s --max-time 5 http://localhost:18080/ || echo "  (port-forward gave no answer)"
  echo
  kill "$PF" 2>/dev/null
fi

echo
echo "--- one-line proof of the ladder ---"
kubectl get svc usms-gateway -n "$NS" \
  -o jsonpath='{"type="}{.spec.type}{"  clusterIP="}{.spec.clusterIP}{"  nodePort="}{.spec.ports[0].nodePort}{"  external="}{.status.loadBalancer.ingress[0].ip}{"\n"}'
exit 0
