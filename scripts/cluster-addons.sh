#!/usr/bin/env bash
# Install the cluster-wide pieces the application manifests assume exist.
#
#   scripts/cluster-addons.sh eks   # metrics-server, ALB controller, cluster autoscaler, ESO
#   scripts/cluster-addons.sh aks   # ESO (AKS already ships metrics-server + node autoscaling)
#   scripts/cluster-addons.sh gke   # ESO (GKE already ships metrics-server + node autoscaling)
#
# Every cloud also gets cert-manager (internal mTLS issuance and rotation) and Reloader
# (turns a renewed Secret into a rolling restart). Add MONITORING=1 to install
# kube-prometheus-stack and the certificate-expiry alerts in k8s/monitoring.
#
# Cloud identity for the secrets operator is passed in, never stored here:
#   EKS: ESO_ROLE_ARN, ALB_ROLE_ARN, CA_ROLE_ARN, CLUSTER_NAME, AWS_REGION, VPC_ID
#   AKS: AZURE_CLIENT_ID, CLUSTER_NAME
#   GKE: GCP_SA_EMAIL, CLUSTER_NAME
set -euo pipefail

CLOUD="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
need() { [[ -n "${!1:-}" ]] || die "missing required environment variable: $1"; }

case "$CLOUD" in
  eks|aks|gke) ;;
  *) die "usage: $(basename "$0") <eks|aks|gke>" ;;
esac

command -v helm >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"

helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null
helm repo update >/dev/null

# --- External Secrets: the only add-on every cloud needs ---------------------------------
say "external-secrets (all clouds)"
need CLUSTER_NAME
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true \
  --wait

# --- cert-manager: issues and rotates the internal certificates --------------------------
# This is the only component that owns auth-mtls / catalog-mtls / gateway-mtls. They are
# deliberately not in External Secrets: two controllers owning one Secret name is a
# reconcile fight that the pods lose.
say "cert-manager (all clouds)"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION:-v1.16.3}" \
  --set crds.enabled=true \
  --wait

# --- Reloader: a renewed Secret must reach the process -----------------------------------
say "reloader (all clouds)"
helm upgrade --install reloader stakater/reloader \
  --namespace reloader \
  --create-namespace \
  --wait

case "$CLOUD" in
  eks)
    need ESO_ROLE_ARN
    # IRSA: the controller assumes a role scoped to the two secrets it may read.
    kubectl -n external-secrets annotate sa external-secrets \
      eks.amazonaws.com/role-arn="$ESO_ROLE_ARN" --overwrite
    kubectl -n external-secrets rollout restart deploy/external-secrets

    need ALB_ROLE_ARN AWS_REGION VPC_ID
    say "aws-load-balancer-controller"
    kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      --namespace kube-system \
      --set clusterName="$CLUSTER_NAME" \
      --set region="$AWS_REGION" \
      --set vpcId="$VPC_ID" \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_ROLE_ARN" \
      --set replicaCount=2 \
      --wait

    need CA_ROLE_ARN
    say "cluster-autoscaler"
    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
      --namespace kube-system \
      --set cloudProvider=aws \
      --set awsRegion="$AWS_REGION" \
      --set autoDiscovery.clusterName="$CLUSTER_NAME" \
      --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$CA_ROLE_ARN" \
      --set extraArgs.balance-similar-node-groups=true \
      --set extraArgs.skip-nodes-with-system-pods=false \
      --set extraArgs.scale-down-delay-after-add=2m \
      --wait

    say "metrics-server (EKS does not ship one)"
    helm upgrade --install metrics-server metrics-server/metrics-server \
      --namespace kube-system \
      --set args[0]=--kubelet-insecure-tls \
      --wait
    kubectl -n kube-system label ns kube-system networking.showcase.io/ingress=true --overwrite
    ;;

  aks)
    need AZURE_CLIENT_ID
    # Workload identity: federation is configured in Terraform, the client id is the link.
    kubectl -n external-secrets annotate sa external-secrets \
      azure.workload.identity/client-id="$AZURE_CLIENT_ID" --overwrite
    kubectl -n external-secrets patch deploy external-secrets --type merge \
      -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'
    kubectl -n kube-system label ns kube-system networking.showcase.io/ingress=true --overwrite
    ;;

  gke)
    need GCP_SA_EMAIL
    kubectl -n external-secrets annotate sa external-secrets \
      iam.gke.io/gcp-service-account="$GCP_SA_EMAIL" --overwrite
    kubectl -n external-secrets rollout restart deploy/external-secrets
    # GCLB traffic does not come from pods, so the GKE overlay uses ipBlock policies; the
    # label keeps the shared policies harmless.
    kubectl -n kube-system label ns kube-system networking.showcase.io/ingress=true --overwrite
    ;;
esac

# --- Optional: scraped metrics and the certificate-expiry alerts -------------------------
# Off by default because it is the one add-on here with a real monthly bill (~1 vCPU and
# 2-3 GiB of Prometheus plus Grafana). The CronJob-free alternative is
# `scripts/cert-expiry.sh --kube`, which needs nothing but kubectl.
if [[ "${MONITORING:-0}" == "1" ]]; then
  say "kube-prometheus-stack (MONITORING=1)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=true \
    --wait
  kubectl apply -f "$ROOT/k8s/monitoring/certificates.yaml"
fi

say "add-ons ready for $CLOUD"
kubectl get pods -n external-secrets
kubectl get pods -n cert-manager
