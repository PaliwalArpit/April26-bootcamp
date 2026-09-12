#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the 3-tier-app assignment end to end:
#   kind (1 control-plane + 3 workers) -> ingress-nginx -> ArgoCD -> CNPG operator
#   -> app secrets (out-of-band, never committed) -> ArgoCD Application
#
# Everything ArgoCD manages lives under manifests/ and is pulled from git, so
# after this script the only way to change the running app is: edit
# manifests/*, commit, push -- ArgoCD's automated sync (prune+selfHeal) takes
# it from there.
#
# Prerequisites: docker (running), kind, kubectl, helm, openssl

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-3-tier-app}"
CNPG_VERSION="${CNPG_VERSION:-1.30.0}"
SECRETS_DIR="${SCRIPT_DIR}/secrets-local"

for cmd in docker kind kubectl helm openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required" >&2; exit 1; }
done

# --- 1. kind cluster -------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists, reusing it."
else
  echo "Creating kind cluster '${CLUSTER_NAME}' (1 control-plane + 3 workers)..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- 2. ingress-nginx (kind-flavored manifest, maps hostPorts 80/443) ------
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo "Installing ingress-nginx..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/kind/deploy.yaml
fi
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# --- 3. ArgoCD --------------------------------------------------------------
if ! kubectl get ns argocd >/dev/null 2>&1; then
  echo "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  kubectl create namespace argocd
  helm install argocd argo/argo-cd -n argocd
fi
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

# --- 4. CloudNativePG operator ----------------------------------------------
if ! kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  echo "Installing CloudNativePG operator ${CNPG_VERSION}..."
  kubectl apply --server-side \
    -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-${CNPG_VERSION}.yaml"
fi
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager --timeout=180s

# --- 5. app secrets (out-of-band -- generated once, never committed) ------
mkdir -p "${SECRETS_DIR}"
if [ ! -f "${SECRETS_DIR}/generated.env" ]; then
  echo "Generating fresh Postgres app-user password + Flask secret key..."
  {
    echo "PG_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')"
    echo "SECRET_KEY=$(openssl rand -hex 24)"
  } > "${SECRETS_DIR}/generated.env"
fi
# shellcheck disable=SC1091
source "${SECRETS_DIR}/generated.env"

kubectl create namespace quiz-app --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic quiz-pg-app-user -n quiz-app \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=quizapp \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic backend-secret -n quiz-app \
  --from-literal=DATABASE_URL="postgresql://quizapp:${PG_PASSWORD}@quiz-pg-rw.quiz-app.svc.cluster.local:5432/devops_learning" \
  --from-literal=SECRET_KEY="${SECRET_KEY}" \
  --from-literal=DB_USERNAME=quizapp \
  --from-literal=DB_PASSWORD="${PG_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 6. ArgoCD Application (this is the only GitOps-managed part) --------
kubectl apply -f "${SCRIPT_DIR}/argocd-application.yaml"

echo
echo "Done. Watch the sync with:"
echo "  kubectl -n argocd get application quiz-app -w"
echo "  kubectl -n quiz-app get pods,cluster,ingress"
echo
echo "ArgoCD UI:"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
