#!/bin/bash

# IMPORTANT: Run this script as system:admin

################################
# CONFIG                       #
################################

GOGS_ADMIN_USER=gogs
GOGS_ADMIN_PASSWORD=openshift
USER_PASSWORD=openshift3
OPENSHIFT_MASTER=$(oc whoami --show-server)
OPENSHIFT_APPS_HOSTNAME=cloudapps.$(oc whoami --show-server | sed "s|https://master\.\(.*\)|\1|g") 
GOGS_HOSTNAME=gogs-lab-infra.$OPENSHIFT_APPS_HOSTNAME
NEXUS_URL=http://nexus-lab-infra.$OPENSHIFT_APPS_HOSTNAME/content/groups/public/

################################
# FUNCTIONS                    #
################################

function wait_while_empty() {
  local _NAME=$1
  local _TIMEOUT=$(($2/5))
  local _CONDITION=$3

  echo "Waiting for $_NAME to be ready..."
  local x=1
  while [ -z "$(eval ${_CONDITION})" ]
  do
    echo "."
    sleep 5
    x=$(( $x + 1 ))
    if [ $x -gt $_TIMEOUT ]
    then
      echo "$_NAME still not ready, I GIVE UP!"
      exit 255
    fi
  done

  echo "$_NAME is ready."
}

function create_lab_infra_project() {
  oc new-project lab-infra
  oc delete limits --all -n lab-infra
  oadm pod-network make-projects-global lab-infra
}

function clean_up_existing_infra() {
  local _PROJECTS=
  # delete projects
  for i in `seq 0 100`; do
    if [ $i -lt 10 ]; then
      _PROJECTS+=" explore-0$i"
    else
      _PROJECTS+=" explore-$i"
    fi
  done

  echo "Deleting projects: $_PROJECTS"
  oc delete project $_PROJECTS

  # delete roadshow guides
  oc delete all -l app=labs -n lab-infra

  # delete gitlab
  oc delete all -l app=gitlab-ce -n lab-infra

  sudo sed -i "s/maxProjects: 1/maxProjects: 3/g" /etc/origin/master/master-config.yaml
  sudo systemctl restart atomic-openshift-master
}



# deploy Gogs
function deploy_gogs() {
oc process -f https://raw.githubusercontent.com/OpenShiftDemos/gogs-openshift-docker/rpm/openshift/gogs-persistent-template.yaml \
  --param=HOSTNAME=$GOGS_HOSTNAME \
  --param=GOGS_VERSION=0.11.4 \
  --param=DATABASE_USER=gogs \
  --param=DATABASE_PASSWORD=gogs \
  --param=DATABASE_NAME=gogs \
  --param=SKIP_TLS_VERIFY=true \
  -n lab-infra | oc create -f - -n lab-infra
}

sleep 2

function deploy_nexus() {
  oc process -f https://raw.githubusercontent.com/OpenShiftDemos/nexus/master/nexus2-persistent-template.yaml \
    -n lab-infra | oc create -f - -n lab-infra
  oc set resources dc/nexus --limits=cpu=1,memory=2Gi --requests=cpu=200m,memory=1Gi -n lab-infra
}

function deploy_guides() {
  oc new-app --name=guides \
    --docker-image=siamaksade/devops-workshop \
    --env=OPENSHIFT_URL=$OPENSHIFT_MASTER \
    --env=OPENSHIFT_APPS_HOSTNAME=$OPENSHIFT_APPS_HOSTNAME \
    --env=OPENSHIFT_USER=userXX \
    --env=OPENSHIFT_PASSWORD=$USER_PASSWORD \
    --env=GIT_SERVER_URL=http://$GOGS_HOSTNAME \
    --env=GIT_SERVER_INTERNAL_URL=http://$GOGS_HOSTNAME \
    # --env=GIT_SERVER_INTERNAL_URL=http://gogs.lab-infra.svc:3000 \
    --env=GIT_USER=userXX \
    --env=GIT_PASSWORD=$USER_PASSWORD \
    --env=PROJECT_SUFFIX=XX \
    -n lab-infra

  oc set probe dc/guides --readiness --liveness --get-url=http://:8080/ --failure-threshold=5 --initial-delay-seconds=15 -n lab-infra
  oc create service clusterip guides --tcp=8080:8080 -n lab-infra
  oc expose svc/guides -n lab-infra
}

function generate_gogs_users() {
  # wait till gogs is up
  wait_while_empty "Gogs PostgreSQL" 600 "oc get ep gogs-postgresql -o yaml -n lab-infra | grep '\- addresses:'"
  wait_while_empty "Gogs" 600 "oc get ep gogs -o yaml -n lab-infra | grep '\- addresses:'"

  # add gogs admin user
  curl -sD - -o /dev/null -L --post302 http://$GOGS_HOSTNAME/user/sign_up \
    --form user_name=$GOGS_ADMIN_USER \
    --form password=$GOGS_ADMIN_PASSWORD \
    --form retype=$GOGS_ADMIN_PASSWORD \
    --form email=$GOGS_ADMIN_USER@gogs.com

  sleep 1

  # create gogs users and repos

  # init cart-service repo
  local _REPO_DIR=/tmp/$(date +%s)-coolstore-microservice
  pushd ~ >/dev/null 
  rm -rf $_REPO_DIR
  mkdir $_REPO_DIR
  cd $_REPO_DIR
  curl -sL -o ./coolstore.zip https://github.com/siamaksade/devops-labs-coolstore/archive/master.zip
  unzip coolstore.zip
  cd devops-labs-coolstore-master/cart-spring-boot
  git init
  git add . --all
  git config user.email "rileydev@redhat.com"
  git config user.name "Riley Developer"
  git commit -m "Initial add" && \
      
  local _GOGS_UID=1 # admin is uid 1
  for i in `seq 0 $1`; do
    _GOGS_UID=$((_GOGS_UID+1))
    if [ $i -lt 10 ]; then
      GOGS_USER=user0$i
    else
      GOGS_USER=user$i
    fi

    echo "Creating user $GOGS_USER (uid=$_GOGS_UID)"
    curl -sD - -o /dev/null -L --post302 http://$GOGS_HOSTNAME/user/sign_up \
      --form user_name=$GOGS_USER \
      --form password=$USER_PASSWORD \
      --form retype=$USER_PASSWORD \
      --form email=$GOGS_USER@gogs.com

    # Create cart-service repository
    read -r -d '' _DATA_JSON << EOM
{
  "name": "cart-service",
  "private": false,
  "auto_init": true,
  "gitignores": "Java",
  "license": "Apache License 2.0",
  "readme": "Default"
}
EOM

    echo "Creating cart-service repo for user $GOGS_USER (uid=$_GOGS_UID)"
    curl -sD - -o /dev/null -L -H "Content-Type: application/json" \
        -d "$_DATA_JSON" \
        -u $GOGS_USER:$USER_PASSWORD \
        -X POST http://$GOGS_HOSTNAME/api/v1/user/repos

    # import cart-service github repo
    git remote add $GOGS_USER http://$GOGS_HOSTNAME/$GOGS_USER/cart-service.git
    git push -f http://$GOGS_USER:$USER_PASSWORD@$GOGS_HOSTNAME/$GOGS_USER/cart-service.git master

   done

  popd >/dev/null
  rm -rf $_REPO_DIR
}

function build_coolstore_images() {
  oc new-project coolstore-images

  # wait for nexus
  wait_while_empty "Nexus" 600 "oc get ep nexus -o yaml -n lab-infra | grep '\- addresses:'"

  # catalog service
  oc new-app redhat-openjdk18-openshift:1.0~https://github.com/siamaksade/devops-labs-coolstore.git \
        --context-dir=catalog-spring-boot \
        --name=catalog \
        --labels=app=coolstore \
        --build-env=MAVEN_MIRROR_URL=$NEXUS_URL \
        -n coolstore-images
  oc cancel-build bc/catalog -n coolstore-images


  # gateway service
  oc new-app redhat-openjdk18-openshift:1.0~https://github.com/siamaksade/devops-labs-coolstore.git \
        --context-dir=gateway-vertx \
        --name=coolstore-gw \
        --labels=app=coolstore \
        --build-env=MAVEN_MIRROR_URL=$NEXUS_URL \
        -n coolstore-images
  oc cancel-build bc/coolstore-gw -n coolstore-images

  # inventory service
  oc new-app redhat-openjdk18-openshift:1.0~https://github.com/siamaksade/devops-labs-coolstore.git \
        --context-dir=inventory-wildfly-swarm \
        --name=inventory \
        --labels=app=coolstore \
        --build-env=MAVEN_MIRROR_URL=$NEXUS_URL \
        -n coolstore-images
  oc cancel-build bc/inventory -n coolstore-images

  # cart service
  oc new-app redhat-openjdk18-openshift:1.0~https://github.com/siamaksade/devops-labs-coolstore.git \
        --context-dir=cart-spring-boot \
        --name=cart \
        --labels=app=coolstore \
        --build-env=MAVEN_MIRROR_URL=$NEXUS_URL \
        -n coolstore-images
  oc cancel-build bc/cart -n coolstore-images

  # web ui
  oc new-app nodejs:4~https://github.com/siamaksade/devops-labs-coolstore.git \
        --context-dir=web-nodejs \
        --name=web-ui \
        --labels=app=coolstore \
        -n coolstore-images
  oc cancel-build bc/web-ui -n coolstore-images

  # we just need the buildconfigs
  oc delete dc,svc -l app=coolstore -n coolstore-images

  # build images
  oc start-build web-ui -n coolstore-images --follow
  oc start-build inventory -n coolstore-images --follow
  oc start-build catalog -n coolstore-images --follow
  oc start-build coolstore-gw -n coolstore-images --follow
  oc start-build cart -n coolstore-images --follow

  # tag in openshift namespace
  oc tag coolstore-images/web-ui:latest       openshift/coolstore-web-ui:prod
  oc tag coolstore-images/inventory:latest    openshift/coolstore-inventory:prod
  oc tag coolstore-images/catalog:latest      openshift/coolstore-catalog:prod
  oc tag coolstore-images/coolstore-gw:latest openshift/coolstore-gateway:prod
  oc tag coolstore-images/cart:latest         openshift/coolstore-cart:prod

  # add coolstore template
  oc create -f https://raw.githubusercontent.com/siamaksade/devops-labs-coolstore/master/openshift/coolstore-deployment-template.yaml -n openshift
}

function set_default_resource_limits() {
  rm -rf /tmp/project-template.yml
  cat <<EOF > /tmp/project-template.yml
apiVersion: v1
kind: Template
metadata:
  name: project-request
objects:
- apiVersion: v1
  kind: Project
  metadata:
    annotations:
      openshift.io/description: \${PROJECT_DESCRIPTION}
      openshift.io/display-name: \${PROJECT_DISPLAYNAME}
      openshift.io/requester: \${PROJECT_REQUESTING_USER}
    name: \${PROJECT_NAME}
  spec: {}
  status: {}
- apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: \${PROJECT_NAME}-quota
  spec:
    hard:
      persistentvolumeclaims: "5"
      pods: 15
      requests.storage: 5Gi
      resourcequotas: 1
- apiVersion: v1
  kind: LimitRange
  metadata:
    creationTimestamp: null
    name: \${PROJECT_NAME}-limits
  spec:
    limits:
    - default:
        cpu: 2000m
        memory: 1048Mi
      defaultRequest:
        cpu: 100m
        memory: 512Mi
      max:
        cpu: 4000m
        memory: 2048Mi
      min:
        cpu: 50m
        memory: 50Mi
      type: Container
- apiVersion: v1
  groupNames:
  - system:serviceaccounts:\${PROJECT_NAME}
  kind: RoleBinding
  metadata:
    creationTimestamp: null
    name: system:image-pullers
    namespace: \${PROJECT_NAME}
  roleRef:
    name: system:image-puller
  subjects:
  - kind: SystemGroup
    name: system:serviceaccounts:\${PROJECT_NAME}
  userNames: null
- apiVersion: v1
  groupNames: null
  kind: RoleBinding
  metadata:
    creationTimestamp: null
    name: system:image-builders
    namespace: \${PROJECT_NAME}
  roleRef:
    name: system:image-builder
  subjects:
  - kind: ServiceAccount
    name: builder
  userNames:
  - system:serviceaccount:\${PROJECT_NAME}:builder
- apiVersion: v1
  groupNames: null
  kind: RoleBinding
  metadata:
    creationTimestamp: null
    name: system:deployers
    namespace: \${PROJECT_NAME}
  roleRef:
    name: system:deployer
  subjects:
  - kind: ServiceAccount
    name: deployer
  userNames:
  - system:serviceaccount:\${PROJECT_NAME}:deployer
- apiVersion: v1
  groupNames: null
  kind: RoleBinding
  metadata:
    creationTimestamp: null
    name: admin
    namespace: \${PROJECT_NAME}
  roleRef:
    name: admin
  subjects:
  - kind: User
    name: \${PROJECT_ADMIN_USER}
  userNames:
  - \${PROJECT_ADMIN_USER}
parameters:
- name: PROJECT_NAME
- name: PROJECT_DISPLAYNAME
- name: PROJECT_DESCRIPTION
- name: PROJECT_ADMIN_USER
- name: PROJECT_REQUESTING_USER
EOF

  oc delete template project-request -n default
  oc create -f /tmp/project-template.yml -n default
}

################################
# MAIN                         #
################################

create_lab_infra_project; sleep 1
deploy_gogs; sleep 1 
clean_up_existing_infra; sleep 1
deploy_nexus; sleep 1
deploy_guides; sleep 1
generate_gogs_users 2; sleep 1
build_coolstore_images; sleep 1
set_default_resource_limits

