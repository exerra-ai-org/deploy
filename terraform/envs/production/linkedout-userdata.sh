#!/usr/bin/env bash
# First boot only. Everything after this is `kubectl apply` from the pipeline.
#
# Deliberately small. This runs once, unattended, with its output going only to
# /var/log/cloud-init-output.log, so anything subtle in here is debugged blind.
# The interesting setup -- ingress, cert-manager, the pull secret, the cluster
# secrets -- lives in scripts/k3s-bootstrap.sh in the linkedout repository,
# where it can be read, re-run and fixed without replacing the instance.
set -euo pipefail

exec > >(tee -a /var/log/linkedout-userdata.log) 2>&1
echo "=== linkedout node bootstrap $(date -Is) ==="

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates jq unzip postgresql-client

# The SSM agent is how this box is reached and deployed to. Ubuntu's is a snap,
# and it is present on Canonical's AMI -- started explicitly because a stopped
# agent presents as an instance that simply never appears in Systems Manager.
snap start amazon-ssm-agent || systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# k3s, with Traefik disabled.
#
# k8s/ingress.yaml is written for ingress-nginx -- ingressClassName: nginx, and
# four nginx-specific annotations, two of which are load-bearing: a 3600s proxy
# read timeout so an idle co-browse WebSocket is not cut at 60s, and an 8m body
# limit so a 5 MB CSV import is not rejected as a 413. Keeping Traefik would mean
# rewriting those annotations into Traefik middlewares, i.e. changing a proven
# manifest to suit an ingress controller nobody chose.
#
# --write-kubeconfig-mode 0644 so the deploy pipeline's SSM commands, which run
# as root, and an operator in a Session Manager shell both read the same file.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb --write-kubeconfig-mode 0644" sh -

# k3s is up when the node is Ready. Without the wait, everything below races it.
for _ in $(seq 1 60); do
    k3s kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 5
done

k3s kubectl get nodes

echo "=== k3s installed. Run scripts/k3s-bootstrap.sh from the linkedout repo next. ==="
