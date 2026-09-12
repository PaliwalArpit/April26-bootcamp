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

# Dedicate one worker to frontend-only and one to backend-only. The taint
# (NoSchedule) blocks anything without a matching toleration; the label is
# what backend/frontend Deployments' nodeSelector actually targets -- a
# toleration alone only permits scheduling there, it doesn't attract it.
# ${CLUSTER_NAME}-worker2 is left untouched: CNPG's Postgres PV is node-pinned
# there (kind's local-path-provisioner), so it -- and anything else (the
# migration Job, etc.) -- naturally lands on the one remaining untainted node.
kubectl label node "${CLUSTER_NAME}-worker" workload=frontend --overwrite
kubectl taint node "${CLUSTER_NAME}-worker" dedicated=frontend:NoSchedule --overwrite
kubectl label node "${CLUSTER_NAME}-worker3" workload=backend --overwrite
kubectl taint node "${CLUSTER_NAME}-worker3" dedicated=backend:NoSchedule --overwrite

# --- 2. ingress-nginx (kind-flavored manifest, maps hostPorts 80/443) ------
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo "Installing ingress-nginx..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/kind/deploy.yaml
fi
# The kind provider manifest's nodeSelector is just kubernetes.io/os=linux, so
# the scheduler is free to place the controller on any worker -- but only the
# control-plane node actually has host ports 80/443 mapped (see kind-config.yaml).
# Pin it to the ingress-ready-labeled control-plane node so localhost:80/443 work.
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux","ingress-ready":"true"}}}}}'
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

# On kind/bare-metal, ingress-nginx never populates Ingress.status.loadBalancer
# (there's no cloud LB to assign one), so ArgoCD's default Ingress health check
# waits forever and any PostSync hook (our migration Job) never fires. Teach it
# to treat Ingress as healthy once created -- standard fix for non-cloud clusters.
kubectl -n argocd patch configmap argocd-cm --type merge --patch '
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    hs.status = "Healthy"
    hs.message = "kind ingress-nginx has no LoadBalancer status; treat as healthy once created"
    return hs
'
kubectl -n argocd delete pod argocd-application-controller-0 --ignore-not-found
kubectl -n argocd wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s

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
