#!/usr/bin/env bash

help() {
  echo "terraform-bootstrap"
  echo ""
  echo "usage:"
  echo "  deploy.sh [COMMAND] [OPTS]"
  echo ""
  echo "options:"
  echo "  -d         set the dir to upload from"
  echo "  -n         set the droplet name"
  echo "  -e         export environment variable from host to vm"
  echo ""
  echo "commands:"
  echo "  up         applies the terraform configuration"
  echo "  dns        updates dns A record address for each public instance"
  echo "  sync       syncs local dir to remote server"
  echo "  provision  runs docker-compose on the droplet if present"
  echo "  status     shows the status of the deployment"
  echo "  down       destroys the deployment"
  echo "  ssh        connects to the droplet via SSH"
  echo "  exec       runs docker-compose exec"
  exit 0
}

updateDNSAction() {
  if [ -n "${NAME}" ]; then
    RECORD_PREFIX="${NAME}-"
  fi
  INSTANCE_NAME="${1}"
  if [ -z "${INSTANCE_NAME}" ]; then
    INSTANCES=$(list | jq -r '.droplets[] | .name + "," + .networks.v4[0].ip_address')
    for i in ${INSTANCES}; do
      INSTANCE_NAME=$(echo "${i}" | awk -F',' '{print $1}')
      INSTANCE_IP=$(echo "${i}" | awk -F',' '{print $2}')
      updateDNS "${RECORD_PREFIX}${INSTANCE_NAME}" "${INSTANCE_IP}"
    done
  else
    updateDNS "${RECORD_PREFIX}${INSTANCE_NAME}" $(publicIPv4 "${INSTANCE_NAME}")
  fi
}

updateDNS() {
  local A_NAME="${1}"
  local IP_ADDR="${2}"
  if [ -z "${A_NAME}" ]; then
    echo "missing A record name"
    exit 1
  fi
  if [ -z "${IP_ADDR}" ]; then
    echo "missing ip address"
    exit 1
  fi
  if [ -n "${ROOT_DOMAIN}" ]; then
    if [ -n "${GODADDY_KEY}" ]; then
      echo "updating ${A_NAME}.${ROOT_DOMAIN} to ${IP_ADDR}"
      curl -sX PUT "https://api.godaddy.com/v1/domains/${ROOT_DOMAIN}/records/A/${A_NAME}" \
        -H 'Content-Type: application/json' \
        -H "Authorization: sso-key ${GODADDY_KEY}:${GODADDY_SECRET}" \
        -d '[{"data":"'${IP_ADDR}'","ttl":600}]'
      echo "updated ${A_NAME}.${ROOT_DOMAIN} to ${IP_ADDR}"
    fi
  fi
}

createTag() {
  local TAG_NAME="${1}"
  curl -s -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    -d '{"name":"'"${TAG_NAME}"'"}' \
    "https://api.digitalocean.com/v2/tags" | jq .
}

deployAction() {
  SSH_PUB_KEY_ID=$(getKeyID)
  if [ "$SSH_PUB_KEY_ID" == "null" -o ! -f "/tmp/${SSH_KEY_NAME}" ]; then
    createKey
    SSH_PUB_KEY_ID=$(getKeyID)
  fi
  createTag "${NAME}"
  export TF_VAR_ssh_key_id="${SSH_PUB_KEY_ID}"
  export TF_VAR_deployment_tag="${NAME}"
  export TF_VAR_ssh_key_private_path="/tmp/${SSH_KEY_NAME}"
  if [ ! -d '.terraform' ]; then
    terraform init ./terraform
  fi
  terraform apply ./terraform
}

syncAction() {
  local INSTANCE_NAME="${1}"
  local IP=$(publicIPv4 "${INSTANCE_NAME}")
  rsync -Pav --delete --exclude='.git/' --filter='dir-merge,- .gitignore' -e "ssh -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/$SSH_KEY_NAME" ${WORKING_DIR} root@${IP}:/
}

asExports() {
  for val in "$@"; do
    echo "export $val='$(echo ${!val})';"
  done
}

provisionAction() {
  local INSTANCE_NAME="${1}"
  local IP_ADDR=$(publicIPv4 "${INSTANCE_NAME}")
  updateDNS "${NAME}-${INSTANCE_NAME}" "${IP_ADDR}"
  if [ -n "$VARS" ]; then
    local HOST_VARS=$(asExports "${VARS[@]}")
  fi
  DP_TAG_MEMBERS=$(status)
  until nc -zvw 1 ${IP_ADDR} 22; do
    sleep 2
  done
  read -r -d "" PROVISION <<EOF
if docker-compose -v > /dev/null; then
  echo "found docker-compose"
else
  sudo curl -o /usr/local/bin/docker-compose -L "https://github.com/docker/compose/releases/download/1.15.0/docker-compose-\$(uname -s)-\$(uname -m)"
  sudo chmod +x /usr/local/bin/docker-compose
  docker-compose -v
fi
${HOST_VARS}
export DP_NAME=${NAME}
export DP_IP_ADDR=${IP_ADDR}
export DP_TAG_MEMBERS="${DP_TAG_MEMBERS}"
if [ -f "/${NAME}/run.sh" ]; then
  . /${NAME}/run.sh ${INSTANCE_NAME}
else
  if [ -f "/${NAME}/docker-compose.yml" ]; then
    docker-compose -f /${NAME}/docker-compose.yml up
  else
    echo "/${NAME}/docker-compose.yml not found"
  fi
fi
EOF
  syncAction ${INSTANCE_NAME}
  ssh root@${IP_ADDR} -o UserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME} -t "$PROVISION"
}

statusAction() {
  status
}

destroyAction() {
  INSTANCE_NAME=$1
  if [ -z "${INSTANCE_NAME}" ]; then
    destroy
    n=0
    until [ $n -ge 30 -o "$(status)" == "down" ]; do
      echo "current status: $(status)"
      n=$[$n+1]
      sleep 1
    done

    if [ "$(status)" != "down" ]; then
      echo "failed to stop"
    else
      statusAction
    fi
  else
    destroy "${INSTANCE_NAME}"
  fi
}

sshAction() {
  INSTANCE_NAME="${1}"
  CMD="${2}"
  IP=$(publicIPv4 "${INSTANCE_NAME}")
  if [ -z "${IP}" ]; then
    echo "failed to find instance named ${INSTANCE_NAME}"
    exit 1
  fi
  if [ -z "${CMD}" ]; then
    ssh root@"${IP}" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME}
  else
    ssh root@"${IP}" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i /tmp/${SSH_KEY_NAME} -t "${CMD}"
  fi
}

getKeys() {
  curl -s -X GET -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/account/keys"
}

getKeyID() {
  echo $(getKeys | jq -c '[ .ssh_keys[] | select( .name | contains("'"$SSH_KEY_NAME"'")).id ][0]' -r)
}

destroyKey() {
  if [ "$(getKeyID)" != "null" ]; then
    curl -s -X DELETE -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/account/keys/$(getKeyID)"
  fi
}

createKey() {
  destroyKey
  rm /tmp/${SSH_KEY_NAME}
  rm /tmp/${SSH_KEY_NAME}.pub
  ssh-keygen -b 2048 -t rsa -f /tmp/${SSH_KEY_NAME} -N ""
  SSH_PUB_KEY=$(cat /tmp/${SSH_KEY_NAME}.pub)
  curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  -d '{"name":"'"$SSH_KEY_NAME"'","public_key":"'"${SSH_PUB_KEY}"'"}' \
  "https://api.digitalocean.com/v2/account/keys" | jq
}

list() {
  curl -s -X GET -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets?tag_name=$NAME"
}

numInstances() {
  echo $(list | jq '.droplets | length')
}

status() {
  if [ "$(numInstances)" = 0 ]; then
    echo "down"
  else
    list | jq -r '.droplets[] | .name + " " + .networks.v4[1].ip_address + " " + .networks.v4[0].ip_address'
  fi
}

publicIPv4() {
  INSTANCE_NAME="${1}"
  echo $(list | jq -r '.droplets[] | select(.name=="'"$INSTANCE_NAME"'") | .networks.v4[0].ip_address')
}

dropletId() {
  INSTANCE_NAME="${1}"
  echo $(list | jq -r '.droplets[] | select(.name=="'"$INSTANCE_NAME"'") | .id')
}

destroy() {
  INSTANCE_NAME=$1
  if [ -z "${INSTANCE_NAME}" ]; then
    terraform destroy ./terraform
  else
    INSTANCE_ID=$(dropletId "${INSTANCE_NAME}")
    curl -X DELETE -H "Content-Type: application/json" \
      -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
      "https://api.digitalocean.com/v2/droplets/${INSTANCE_ID}"
  fi
}

if [ -f ".env" ]; then
  source .env
fi

if ! which jq 2>&1 > /dev/null; then
  echo 'missing required dependency jq (https://stedolan.github.io/jq/)'
  exit 1
fi

if [ -z "$DIGITALOCEAN_TOKEN" ]; then
  echo 'missing required env variable DIGITALOCEAN_TOKEN'
  exit 1
fi

ACTION=$1;shift
NAME=$(basename "${SCRIPT_PATH}")
WORKING_DIR=$(pwd -P)
REMOTE_CMD=""
if [[ ! "${1}" == -* ]]; then
   ARG=$1;shift
fi
if [[ ! "${1}" == -* ]]; then
   ARG_2=$1;shift
fi
if [[ ! "${1}" == -* ]]; then
   ARG_3=$1;shift
fi

while getopts d:n:e:,l flag; do
  case $flag in
  d)
    WORKING_DIR=$OPTARG
    ;;
  n)
    NAME=$OPTARG
    ;;
  e)
    VARS+=("$OPTARG")
    ;;
  ?)
    ACTION="help"
    ;;
  esac
done

if [ ! -d "${WORKING_DIR}" ]; then
  echo "supplied dir not found - ${WORKING_DIR}"
  exit 1
fi

if [ -z "${NAME}" ]; then
  NAME=$(basename "$WORKING_DIR")
fi

SSH_KEY_NAME="${NAME}_ssh"

if [ -z "${ACTION}" -o "${ACTION}" = "help" ]; then
  help
fi

if [ "${ACTION}" = "up" ]; then
  deployAction
elif [ "${ACTION}" = "dns" ]; then
  updateDNSAction "${ARG}"
elif [ "${ACTION}" = "sync" ]; then
  syncAction "${ARG}"
elif [ "${ACTION}" = "provision" ]; then
  provisionAction "${ARG}"
elif [ "${ACTION}" = "status" ]; then
  statusAction
elif [ "${ACTION}" = "down" ]; then
  destroyAction "${ARG}"
elif [ "${ACTION}" = "ssh" ]; then
  sshAction "${ARG}"
elif [ "${ACTION}" = "stop" ]; then
  INSTANCE_TYPE=$(echo "${ARG}" | awk -F'-' '{print $1}')
  sshAction "${ARG}" "cd /${NAME} && docker-compose -f docker-compose-${INSTANCE_TYPE}.yml stop"
elif [ "${ACTION}" = "exec" ]; then
  INSTANCE_TYPE=$(echo "${ARG}" | awk -F'-' '{print $1}')
  COMPOSE_SERVICE=${ARG_2}
  CMD=${ARG_3}
  if [ -z "${CMD}" ]; then
    CMD="${COMPOSE_SERVICE}"
    COMPOSE_SERVICE=${INSTANCE_TYPE}
  fi
  if [ -z "${CMD}" ]; then
    CMD="bash"
  fi
  echo "running ${CMD} on ${COMPOSE_SERVICE}"
  sshAction "${ARG}" "cd /${NAME} && docker-compose -f docker-compose-${INSTANCE_TYPE}.yml exec ${COMPOSE_SERVICE} ${CMD}"
elif [ "${ACTION}" = "logs" ]; then
  INSTANCE_TYPE=$(echo "${ARG}" | awk -F'-' '{print $1}')
  COMPOSE_SERVICE=${ARG_2}
  sshAction "${ARG}" "cd /${NAME} && docker-compose -f docker-compose-${INSTANCE_TYPE}.yml logs --follow --tail='100' ${COMPOSE_SERVICE}"
fi

exit 0
