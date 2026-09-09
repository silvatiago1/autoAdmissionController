# In order to have metrics as accurate as possible, remove internet impact by pulling the images into minikube:

docker pull ubuntu:22.04

minikube image load ubuntu:22.04

## Verify:
minikube image ls | grep ubuntu

## Workflows need to be edited to use local image, for example:
container:
  image: ubuntu:22.04
  imagePullPolicy: IfNotPresent