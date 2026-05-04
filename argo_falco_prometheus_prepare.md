# Argo
kubectl create namespace argo

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --version 0.45.21 \
  --set server.serviceType=ClusterIP

## Check status
kubectl get pods -n argo

## RBAC (This is overly permissive, only used for test purposes)
kubectl create rolebinding default-admin \
  --clusterrole=admin \
  --serviceaccount=argo:default \
  -n argo


## Enable UI
kubectl port-forward svc/argo-workflows-server -n argo 2746:2746

# Falco
helm install --replace falco --namespace falco --create-namespace --set tty=true falcosecurity/falco

## Disable default rules and apply created rules
helm upgrade --namespace falco falco falcosecurity/falco --set tty=true -f disable_rules.yaml -f detect_unwanted.yaml

## Wait for status to be ready:
kubectl wait pods --for=condition=Ready --all -n falco

## Logs
kubectl logs -f --tail=50 -l app.kubernetes.io/name=falco -n falco -c falco


# Prometheus-stack
helm install monitoring prometheus-community/kube-prometheus-stack

kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090