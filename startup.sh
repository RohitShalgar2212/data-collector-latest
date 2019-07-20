#!/bin/sh

SCH_ORG=accenture2.com
SCH_USER=admin@accenture2.com 
SCH_PASSWORD=P@555word 
SCH_URL=https://cloud.streamsets.com 
KUBE_NAMESPACE=streamsets



if [ -z "$(which jq)" ]; then
  echo "This script requires the 'jq' utility."
  echo "Please install it from https://stedolan.github.io/jq/"
  echo "or your favorite package manager."
  echo "On macOS you can install it via Homebrew using 'brew install jq'"
  exit 1
fi

if [ -z "$(which kubectl)" ]; then
  echo "This script requires the 'kubectl' utility."
  echo "Please install it via one of the methods described here:"
  echo "https://kubernetes.io/docs/tasks/tools/install-kubectl/"
  exit 1
fi

if [ -z "$SCH_ORG" ]; then
  show_usage
  echo "Please set SCH_ORG to your organization name."
  echo "This is the part of your login after the '@' symbol"
  exit 1
fi

if [ -z "$SCH_USER" ]; then
  show_usage
  echo "Please set SCH_USER to your username in the form 'user@org'"
  exit 1
fi

if [ -z "$SCH_PASSWORD" ]; then
  show_usage
  echo "Please set SCH_PASSWORD to your StreamSets Control Hub password"
  exit 1
fi

: ${SCH_URL:=https://cloud.streamsets.com}
SCH_TOKEN=$(curl -s -X POST -d "{\"userName\":\"${SCH_USER}\", \"password\": \"${SCH_PASSWORD}\"}" ${SCH_URL}/security/public-rest/v1/authentication/login --header "Content-Type:application/json" --header "X-Requested-By:SDC" -c - | sed -n '/SS-SSO-LOGIN/p' | perl -lane 'print $F[$#F]')

if [ -z "$SCH_TOKEN" ]; then
  echo "Failed to authenticate with SCH :("
  echo "Please check your username, password, and organization name."
  exit 1
fi




KUBE_USERNAME=kubeadm

# Set the namespace
kubectl create namespace ${KUBE_NAMESPACE}
kubectl config set-context $(kubectl config current-context) --namespace=${KUBE_NAMESPACE}


kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user="$KUBE_USERNAME"

kubectl create serviceaccount streamsets-agent --namespace=${KUBE_NAMESPACE}

#kubectl create role streamsets-agent \
#     --apiGroups: [""] 	\
#     --verb=get,list,create,update,delete \
#     --resource=pods,secrets,deployments \
#     --namespace=${KUBE_NAMESPACE}

kubectl create -f create-role.yaml

kubectl create rolebinding streamsets-agent \
     --role=streamsets-agent \
     --serviceaccount=${KUBE_NAMESPACE}:streamsets-agent \
     --namespace=${KUBE_NAMESPACE}




#######################
# Setup Control Agent #
#######################

# 1. Get a token for Agent from SCH and store it in a secret
AGENT_TOKEN=$(curl -s -X PUT -d "{\"organization\": \"${SCH_ORG}\", \"componentType\" : \"provisioning-agent\", \"numberOfComponents\" : 1, \"active\" : true}" ${SCH_URL}/security/rest/v1/organization/${SCH_ORG}/components --header "Content-Type:application/json" --header "X-Requested-By:SDC" --header "X-SS-REST-CALL:true" --header "X-SS-User-Auth-Token:${SCH_TOKEN}" | jq  -e -r '.[0].fullAuthToken')
if [ -z "$AGENT_TOKEN" ]; then
  echo "Failed to generate control agent token."
  echo "Please verify you have Provisioning Operator permissions in SCH"
  exit 1
fi
kubectl create secret generic sch-agent-creds \
    --from-literal=dpm_agent_token_string=${AGENT_TOKEN}

# 2. Create secret for agent to store key pair
kubectl create secret generic compsecret

# 3. Create config map to store configuration referenced by the agent yaml

agent_id=$(uuidgen)
echo ${agent_id} > agent.id
kubectl create configmap streamsets-config \
    --from-literal=org=${SCH_ORG} \
    --from-literal=sch_url=${SCH_URL} \
    --from-literal=agent_id=${agent_id}

# 4. Launch Agent
kubectl create -f control-agent.yaml

# 5. wait for agent to be registered with SCH
temp_agent_Id=""
while [ -z $temp_agent_Id ]; do
  sleep 10
  temp_agent_Id=$(curl -L "${SCH_URL}/provisioning/rest/v1/dpmAgents?organization=${SCH_ORG}" --header "Content-Type:application/json" --header "X-Requested-By:SDC" --header "X-SS-REST-CALL:true" --header "X-SS-User-Auth-Token:${SCH_TOKEN}" | jq -r -e "map(select(any(.id; contains(\"${agent_id}\")))|.id)[]")
done
echo "DPM Agent \"${temp_agent_Id}\" successfully registered with SCH"

