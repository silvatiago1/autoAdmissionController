# Argo
kubectl create namespace argo

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --version 0.45.21 \
  --set server.serviceType=ClusterIP \
  --set images.pullPolicy=IfNotPresent
  
### If the images are not being found: 
kubectl -n kube-system edit configmap coredns
### And change the forward to 8.8.8.8 1.1.1.1

## Check status
kubectl get pods -n argo

## RBAC (This is overly permissive, only used for test purposes)
kubectl create rolebinding default-admin \
  --clusterrole=admin \
  --serviceaccount=argo:default \
  -n argo


## Enable UI
kubectl port-forward svc/argo-workflows-server -n argo 2746:2746

## Add Minio Artifact Storage

### Minio
helm install argo-artifacts minio/minio \
  --namespace argo \
  --set mode=standalone \
  --set rootUser=minioadmin \
  --set rootPassword=minioadmin \
  --set resources.requests.memory=1Gi \
  --set persistence.size=5Gi \
  --set service.type=LoadBalancer \
  --set fullnameOverride=argo-artifacts

### Apply Minio
In this repo, go to /minio and apply the configuration present in there

minikube tunnel
### Test if Minio is working
kubectl get svc -n argo argo-artifacts

kubectl run -n argo mc --image=minio/mc --restart=Never --command -- sleep 3600
kubectl exec -n argo -it mc -- mc alias set local http://argo-artifacts.argo.svc.cluster.local:9000 minioadmin minioadmin
kubectl exec -n argo -it mc -- mc admin info local
kubectl exec -n argo -it mc -- mc mb local/my-bucket
kubectl exec -n argo -it mc -- mc ls local

# Falco
helm install --replace falco --namespace falco --create-namespace --set tty=true falcosecurity/falco

## Disable default rules and apply created rules
helm upgrade --namespace falco falco falcosecurity/falco \
  --set tty=true \
  --set falcoctl.artifact.install.enabled=false \
  --set falcoctl.artifact.follow.enabled=false \
  -f disable_rules.yaml -f detect_unwanted.yaml

## Wait for status to be ready:
kubectl wait pods --for=condition=Ready --all -n falco

## Logs
kubectl logs -f --tail=50 -l app.kubernetes.io/name=falco -n falco -c falco


# Prometheus-stack
helm install monitoring prometheus-community/kube-prometheus-stack

kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090