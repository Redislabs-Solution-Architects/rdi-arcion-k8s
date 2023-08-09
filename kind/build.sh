
#!/bin/bash
echo -e "\n*** Create K8S (Kind) Cluster ***"
kind create cluster --config=$PWD/kind/config.yaml --name $USER-redis-cluster

echo -e "\n*** Load Arcion Replicant Image ***"
if [ -z "$(docker images -q arcion/replicant-cli:$REPLICANT_VERSION)" ]
then
  echo "Building Arcion Replicant Image"
  envsubst < ./arcion/Dockerfile | docker build -t arcion/replicant-cli:$REPLICANT_VERSION -
fi
kind --name $USER-redis-cluster load docker-image arcion/replicant-cli:$REPLICANT_VERSION


echo -e "\n*** Create Loadbalancer ***"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml; sleep 5
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=-1s
SUBNET=`docker network inspect kind | jq '.[].IPAM.Config[0].Subnet' | cut -d . -f 1,2,3 | sed -e 's/^"//'`
ADDRESSES=${SUBNET}.10-${SUBNET}.100
cat > $PWD/kind/metallb.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
  - $ADDRESSES
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF
kubectl apply -f $PWD/kind/metallb.yaml