# Argo
kubectl create namespace argo

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --version 0.45.21 \
  --set server.serviceType=ClusterIP

## Check status
kubectl get pods -n argo

## Enable UI
kubectl port-forward svc/argo-workflows-server -n argo 2746:2746

## RBAC (This is overly permissive, only used for test porpuses)

kubectl create rolebinding default-admin \
  --clusterrole=admin \
  --serviceaccount=argo:default \
  -n argo

# Kyverno
kubectl create namespace kyverno

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --version 3.2.6

kubectl get pods -n kyverno

# Tetragon
helm install tetragon ${EXTRA_HELM_FLAGS[@]} cilium/tetragon -n kube-system

kubectl rollout status -n kube-system ds/tetragon -w
