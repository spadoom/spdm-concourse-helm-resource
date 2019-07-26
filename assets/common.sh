#!/bin/bash
set -x

setup_kubernetes() {
    payload=$1
    source=$2
    mkdir -p /root/.kube
    gcloud_auth=$(jq -r '.source.gcloud_auth // ""' < $payload)
    kubeconfig=$(jq -r '.source.kubeconfig // ""' < $payload)
    
    if [ -n "$gcloud_auth" ]; then
        echo "$gcloud_auth" > gcloud-auth-key.json
        gcloud_project=$(jq -r '.source.gcloud_project // ""' < $payload)
        gcloud_cluster=$(jq -r '.source.gcloud_cluster // ""' < $payload)
        gcloud_zone=$(jq -r '.source.gcloud_zone // ""' < $payload)
        
        gcloud --quiet auth activate-service-account --key-file gcloud-auth-key.json
        gcloud --quiet config set project $gcloud_project
        gcloud --quiet config set compute/zone $gcloud_zone
        gcloud --quiet config set container/cluster $gcloud_cluster
        gcloud --quiet container clusters get-credentials $gcloud_cluster
        
    elif [ -n "$kubeconfig" ]; then
        echo "$kubeconfig" > /root/.kube/config
    else
        echo "Must specify either \"gcloud_auth\" or \"kubeconfig\" for authenticating to Kubernetes."
        exit 1
    fi
    
    kubectl cluster-info
    kubectl version
}


call_helm() {
    export last="${@: -1}"
    array=( "$@" )
    unset "array[${#array[@]}-1]"
    logfile="/tmp/log"
    mkdir -p /tmp
    helm ${array[@]} $TLS --tiller-namespace=$TILLER_NAMESPACE $last | tee $logfile
    release=`cat $logfile | grep "NAME:" | awk '{print $2}'`
}

setup_helm() {
    init_server=$(jq -r '.source.helm_init_server // "false"' < $1)
    export TILLER_NAMESPACE=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)
    export TLS=""
    if [ "$init_server" = true ]; then
        tiller_service_account=$(jq -r '.source.tiller_service_account // "default"' < $1)
        helm init --tiller-namespace=$TILLER_NAMESPACE --service-account=$tiller_service_account --upgrade
        wait_for_service_up tiller-deploy 10
    else
        helm init --client-only --tiller-namespace $TILLER_NAMESPACE > /dev/null
    fi
    
    ca_cert=$(jq -r '.source.ca_cert // ""' < $1)
    client_cert=$(jq -r '.source.client_cert // ""' < $1)
    client_key=$(jq -r '.source.client_key // ""' < $1)
    repo_ca_cert=$(jq -r '.source.repo_ca_cert // ""' < $1)

    if [ -n "$ca_cert" ]; then
        if [ -z "$client_cert" ]; then
            echo "Must specify \"client_cert\"!"
            exit 1
        fi
        
        if [ -z "$client_key" ]; then
            echo "Must specify \"client_key\"!"
            exit 1
        fi
        
        echo "$ca_cert" > $(helm home)/ca.pem
        echo "$client_cert" > $(helm home)/cert.pem
        echo "$client_key" > $(helm home)/key.pem

        export TLS="--tls"
    fi
    if [ -n "$repo_ca_cert" ]; then
        echo "$repo_ca_cert" > $(helm home)/repo_ca.pem
    fi
    call_helm version
}

wait_for_service_up() {
    SERVICE=$1
    TIMEOUT=$2
    if [ "$TIMEOUT" -le "0" ]; then
        echo "Service $SERVICE was not ready in time"
        exit 1
    fi
    RESULT=`kubectl get endpoints --namespace=$TILLER_NAMESPACE $SERVICE -o jsonpath={.subsets[].addresses[].targetRef.name} 2> /dev/null || true`
    if [ -z "$RESULT" ]; then
        sleep 1
        wait_for_service_up $SERVICE $((--TIMEOUT))
    fi
}

setup_repos() {
    repos=$(jq -r '(try .source.repos[] catch [][]) | (.name+" "+.url)' < $1)
    TILLER_NAMESPACE=$(jq -r '.source.tiller_namespace // "kube-system"' < $1)
    
    IFS=$'\n'
    for r in $repos; do
        name=$(echo $r | cut -f1 -d' ')
        url=$(echo $r | cut -f2 -d' ')
        echo Installing helm repository $name $url
        helm repo add --ca-file $(helm home)/repo_ca.pem --tiller-namespace $TILLER_NAMESPACE $name $url
    done
}

setup_resource() {
    echo "Initializing kubectl..."
    setup_kubernetes $1 $2
    echo "Initializing helm..."
    setup_helm $1
    setup_repos $1
}
