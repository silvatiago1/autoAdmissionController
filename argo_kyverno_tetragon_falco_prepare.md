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

# Tetragon //This setup works with kprobe, but not with lsm hooks
helm install tetragon cilium/tetragon -n kube-system \
  --set tetragon.hostNetwork=true \
  --set tetragon.securityContext.privileged=true

kubectl rollout status -n kube-system ds/tetragon -w

kubectl port-forward -n kube-system ds/tetragon 54321:54321

# Falco
helm install --replace falco --namespace falco --create-namespace --set tty=true falcosecurity/falco

kubectl wait pods --for=condition=Ready --all -n falco

## Disable default rules and apply created rules
helm upgrade --namespace falco falco falcosecurity/falco --set tty=true -f disable_rules.yaml -f detect_unwanted.yaml