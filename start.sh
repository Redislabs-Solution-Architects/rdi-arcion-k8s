#!/bin/bash
# Usage: start.sh
# Description:  Builds a 3-worker K8S cluster.  Starts a 3-node Redis Enterpise cluster + Redis target DB, 
# builds a MSSQL source DB in CT mode, deploys a Redis DI CLI pod, and deploys a Arcion replicant pod.

export REPLICANT_VERSION="23.05.31.11"
export REPLICANT_IMAGE=arcion/replicant-cli:${REPLICANT_VERSION}
./kind/build.sh

echo -e "\n*** Create Redis Operator ***"
kubectl create namespace re
kubectl config set-context --current --namespace=re
RE_LATEST=`curl --silent https://api.github.com/repos/RedisLabs/redis-enterprise-k8s-docs/releases/latest | grep tag_name | awk -F'"' '{print $4}'`
kubectl apply -f https://raw.githubusercontent.com/RedisLabs/redis-enterprise-k8s-docs/$RE_LATEST/bundle.yaml; sleep 1
kubectl rollout status deployment redis-enterprise-operator

echo -e "\n*** Create Redis Cluster ***"
REC_USER="demo@redis.com"
REC_PWD=$(apg -a 1 -m 20 -n 1 -M NCL)
echo "REC Username: $REC_USER"
echo "REC Password: $REC_PWD"
export REC_USER_B64=$(echo -n $REC_USER | base64)
export REC_PWD_B64=$(echo -n $REC_PWD | base64)
export REC_NAME=mycluster
envsubst < ./redis/rec.yaml | kubectl apply -f -; sleep 1
kubectl rollout status sts/$REC_NAME
kubectl exec -it $REC_NAME-0 -c redis-enterprise-node -- curl -s https://redismodules.s3.amazonaws.com/redisgears/redisgears_python.Linux-ubuntu18.04-x86_64.1.2.6.zip -o /tmp/redis-gears.zip
kubectl exec -it $REC_NAME-0 -c redis-enterprise-node -- curl -s -o /dev/null -k -u "$REC_USER:$REC_PWD" https://localhost:9443/v2/modules -F module=@/tmp/redis-gears.zip
while [ -z "$(kubectl exec -it $REC_NAME-0 -c redis-enterprise-node -- curl -s -k -u "$REC_USER:$REC_PWD" https://localhost:9443/v1/modules | \
jq '.[] | select(.display_name=="RedisGears").semantic_version')" ]
do  
  sleep 3
done

echo -e "\n*** Create Redis Database ***"
export JSON_VERSION=`kubectl exec -it $REC_NAME-0 -c redis-enterprise-node -- \
curl -k -u "$REC_USER:$REC_PWD" https://localhost:9443/v1/modules | jq '.[] | select(.display_name=="RedisJSON").semantic_version' | tr -d '"'`

export SEARCH_VERSION=`kubectl exec -it $REC_NAME-0 -c redis-enterprise-node -- \
curl -k -u "$REC_USER:$REC_PWD" https://localhost:9443/v1/modules | jq '.[] | select(.display_name=="RediSearch 2").semantic_version' | tr -d '"'`

export REDB_USER="default"
export REDB_PWD=$(apg -a 1 -m 20 -n 1 -M NCL)
echo "REDB Username: $REDB_USER"
echo "REDB Password: $REDB_PWD"
export REDB_USER_B64=$(echo -n $REDB_USER | base64)
export REDB_PWD_B64=$(echo -n $REDB_PWD | base64)
export REDB_NAME="mydb"
export REDB_PORT=12000
envsubst < ./redis/redb.yaml | kubectl apply -f -
REDB_HOST=""
while [ -z $REDB_HOST ]
do
  sleep 3
  REDB_HOST=$(kubectl get service $REDB_NAME-load-balancer -o jsonpath='{.status.loadBalancer.ingress[0].*}' 2>/dev/null)
done
echo "REDB Host and Port: $REDB_HOST $REDB_PORT"

echo -e "\n*** Create RDI ***"
export RDI_PORT=13000
export RDI_PWD=$(apg -a 1 -m 20 -n 1 -M NCL)
echo "RDI Password: $RDI_PWD"
envsubst < ./rdi/config-template.yaml > ./rdi/config.yaml
kubectl create configmap redis-di-config --from-file=./rdi/config.yaml
kubectl create configmap redis-di-jobs --from-file=./rdi/jobs
kubectl apply -f ./rdi/rdi-cli.yaml
kubectl wait --for=condition=ready pod --selector=app=rdi-cli --timeout=-1s
kubectl exec -it rdi-cli -- redis-di create --silent --cluster-host $REC_NAME --cluster-api-port 9443 --cluster-user $REC_USER \
--cluster-password $REC_PWD --rdi-port $RDI_PORT --rdi-password $RDI_PWD
while [ -z "$(kubectl get service redis-di-1-load-balancer -o jsonpath='{.status.loadBalancer.ingress[0].*}' 2>/dev/null)" ]
do 
  sleep 3
done
kubectl exec -it rdi-cli -- redis-di deploy --dir /app --rdi-host redis-di-1-load-balancer --rdi-port $RDI_PORT --rdi-password $RDI_PWD

echo -e "\n*** Create MSSQL Database ***"
kubectl create namespace ms
kubectl config set-context --current --namespace=ms
export MSSQL_USER=sa
export MSSQL_PWD=$(apg -a 1 -m 20 -n 1 -M NCL)
echo "MSSQL Username: $MSSQL_USER"
echo "MSSQL Password: $MSSQL_PWD"
envsubst < ./mssql/mssql.yaml | kubectl apply -f -; sleep 1
kubectl rollout status sts/mssql; sleep 5
kubectl cp ./mssql/chinook.sql mssql-0:/tmp/chinook.sql
kubectl exec mssql-0 -- /opt/mssql-tools/bin/sqlcmd -U sa -P $MSSQL_PWD -i /tmp/chinook.sql >/dev/null

echo -e "\n*** Create Arcion Replicant ***"
kubectl create namespace arcion
kubectl config set-context --current --namespace=arcion
kubectl create configmap replicant-license --from-file=./arcion/replicant.lic
envsubst < ./arcion/rdi_mssqlct/source.template > ./arcion/rdi_mssqlct/source.yaml
envsubst < ./arcion/rdi_mssqlct/target.template > ./arcion/rdi_mssqlct/target.yaml
kubectl create configmap replicant-config --from-file=./arcion/rdi_mssqlct
envsubst < ./arcion/replicant.yaml | kubectl apply -f -; sleep 1
kubectl rollout status deployment replicant

echo -e "\n*** Build Complete ***"
echo "K8S Cluster env:  kubectl get nodes"
echo "Redis K8S env:  kubectl -n re get all"
echo "MSSQL sqlcmd:  kubectl -n ms exec -it mssql-0 -- /opt/mssql-tools/bin/sqlcmd -U sa -P $MSSQL_PWD"
echo "RDI status:  kubectl -n re exec -it rdi-cli -- redis-di status --rdi-host redis-di-1-load-balancer --rdi-port $RDI_PORT --rdi-password $RDI_PWD"