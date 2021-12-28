#!/bin/bash
set -o errexit -o pipefail -o nounset

## Process
# 1. set nodepool via label and region
# 2. login to aws cli
# 3. run script `▶ sh rotate_node_pools.sh -n 'highmem' -v '1.18.20' -r 'us-east-1'`
# 4. re try run script `▶ sh rotate_node_pools.sh -n 'highmem' -v '1.18.20' -r 'us-east-1' -x 'true'`

## Script process/ordering
# 1. drains single node from nodepool
# 2. checks drained node is unschduleable and has no actively used namespaces on it
# 3. terminate the drained node
#       a. check node has been deleted before continuing
#       b. check it has been replaced by new node before continuing
# 4. repeat step 1 for next node

# global vars
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
PROJECTDIR=`pwd`
UNSCHEDULEABLE="false"
red=$'\e[1;31m'
green=$'\e[1;32m'
blue=$'\e[1;34m'
end=$'\e[0m'
check_drained_counter=0
terminate_node_counter=0
NODES=""
tmpfile=$(mktemp $SCRIPTDIR/$date.lastrun.txt)
exec 3>"$tmpfile"

# defaults
INITIAL_NODE_COUNT=0
nodeErrorCode=0
drainErrorCode=0
RETRY=false

# list of namespaces that should not be on a drained node
# To-do invert this list to what is espected
declare -a NODE_ACTIVE_NAMESPACES
NODE_ACTIVE_NAMESPACES+=(argo-events argo-observer argocd argowf cert-manager cloudability cluster-autoscaler computation external-dns functionsd glance ingress iox)
NODE_ACTIVE_NAMESPACES+=(istio-operator istio-system kafka-operator keda kube-node-lease kube-public kvmigrate newrelic-minion notebooksd ops pinneditemsd pipescope)
NODE_ACTIVE_NAMESPACES+=(sampleappd sealed-secrets telegraf-operator twodotoh vault vault-secrets-manager velero)

drain_nodes() {
    for i in $NODES; do 
    kubectl drain $i --delete-emptydir-data  --ignore-daemonsets --as=admin
    sleep 5
    # double drain as its cheap insurence and should happen quick the second time
    kubectl drain $i --delete-emptydir-data  --ignore-daemonsets --as=admin
    # check second drain exit status if non 0 exit
    drainErrorCode=$?
    if [ $drainErrorCode -ne 0 ]; then
        printf "%s\n" "${red}ERROR: Kubectl drain node command exited with non 0${end}"
        exit 126
    fi
    # check if node is unschedulable and check if any namespace from exclusion list are active within `k describe node`
    check_drained $i
    # terminate node so autoscaler can re add node
    terminate_node $i
    done
}

check_drained () {
    UNSCHEDULEABLE=$(kubectl get node $1 -o=jsonpath='{.spec.unschedulable}')
    # check if unschedulable
    if [ "$UNSCHEDULEABLE" == "true" ] ; then
        printf "%s\n" "${blue}Node is unschedulable${end}"
        printf "%s\n" "${blue}Check for active namespaces on node $1 ${end}"
        ACTIVE_POD_COUNT=$(kubectl describe node $1 | grep "Non-terminated Pods" | grep -Eo '[0-9]{1,3}')
        # filters out junk messages and only prints Non-terminated Pods from the grep
        NODEDESCRIPTION=$(kubectl describe node $1 | grep -A$ACTIVE_POD_COUNT "Namespace")
        # check for namespace from exclusion list
        for a in ${NODE_ACTIVE_NAMESPACES[@]}; do
        if [[ $NODEDESCRIPTION == *"$a"* ]]; then
            printf "%s\n" "${red}ERROR: Status -- Namespace $a present on node check -- FAIL ${end}"
            check_drained_counter=$((check_drained_counter+1))
            # retry if nodes arent fully drain from race condition
            check_drained
            sleep 10
        elif [[ $NODEDESCRIPTION == *"$a"* && "$check_drained_counter" -gt 6 ]]; then
            printf "%s\n" "${red}ERROR: Status -- Namespace $a present on node check -- FAIL ${end}"
            printf "%s\n" "${red}ERROR: Status -- Counter: $check_drained_counter times reached; Exiting loop!${end}"
            exit 1
        fi
        done
    else     
        printf "%s\n" "${red}ERROR: Node should be unschedulable if it was drained${end}" 
        exit 1
    fi
}

terminate_node () {
    # node should be unschedulable if terminating ec2 instance
    K8_NODE_NAME=$1
    UNSCHEDULEABLE=$(kubectl get node $K8_NODE_NAME -o=jsonpath='{.spec.unschedulable}')
    if [ "$UNSCHEDULEABLE" == "true" ] ; then 
        # get aws ec2 instance name for termination
        NODE=$(kubectl  get node $K8_NODE_NAME -o jsonpath='{.spec.providerID}' | awk -F/ '{print $5}')
        printf "%s\n" "${blue}Terminating node: $NODE via aws cli${end}"
        # check function gets drained node
        check_node () {
            # no exit on this command but save error code to pass along to other function
            set -e
            kubectl get node $K8_NODE_NAME || nodeErrorCode=$?
        }
        check_node
        # count nodes in pool
        INITIAL_NODE_COUNT=$(kubectl get node -l $NODEPOOL_LABEL --no-headers | wc -l) 
        # terminate aws instance
        aws ec2 terminate-instances --region $REGION --instance-ids $NODE
        # arbitrary sleep
        sleep 3
        # recursive shit function to check node is down before proceeding to avoid racing condition
        check_termination () {
            check_node
            if [ $nodeErrorCode -ne 0 ]; then
                printf "%s\n" "${blue}k8 Node Name: $K8_NODE_NAME EC2 Node Name: $NODE has been terminated ${end}"
                # remove node from lastrun.txt as it has been terminated
                sed -i "" "/$K8_NODE_NAME/d" $SCRIPTDIR/lastrun.txt
                # below does not work on macos
                #sed -i "/$K8_NODE_NAME/d" $SCRIPTDIR/lastrun.txt
                NODES_REMAINING=$(cat $SCRIPTDIR/lastrun.txt | wc -l)
                printf "%s\n" "${green}Status -- Nodes Remaining: $NODES_REMAINING ${end}"
            elif [[ "$terminate_node_counter" -gt 10 ]]; then
                printf "%s\n" "${red}ERROR: Counter: $terminate_node_counter times reached; Exiting loop!${end}"
                exit 1
            else 
                printf "%s\n" "${blue}Pause 15s while k8 Node Name: $K8_NODE_NAME EC2 Node Name: $NODE is being terminated ${end}"
                sleep 15
                terminate_node_counter=$((terminate_node_counter+1))
                check_termination
            fi
        }
        check_termination
    else
        printf "%s\n" "${red}ERROR: Node should be unschedulable for ec2 termination${end}" 
        exit 1
    fi
}

# clean up lastrun.txt if empty
cleanup () {
    [ -s lastrun.txt ] || rm -f $SCRIPTDIR/lastrun.txt
}

set_vars () {
    while getopts n:v:r:x: flag
    do
        case "${flag}" in
            n) NODEPOOL_NAME=${OPTARG};;
            v) NODE_VERSION_TO_DRAIN=${OPTARG};;
            r) REGION=${OPTARG};;
            x) RETRY=${OPTARG};;
        esac
    done

    if [[ "$NODEPOOL_NAME" == "" || "$NODE_VERSION_TO_DRAIN" == ""|| "$REGION" == ""  ]]; then
        printf "%s\n" "${red}ERROR: Options -n, -v and -r require arguments.${end}"
        exit 1
    fi
}

# drain vars
NODEPOOL_LABEL="awslabeler.influxdata.com/type=$NODEPOOL_NAME"

set_vars

if [ $RETRY == false ]; then
    printf "%s\n" "${green}Draining nodes for nodes with label $NODEPOOL_LABEL ${end}"
    # get nodes in pool by label count intial ready nodes
    NODES=$(kubectl get node -l $NODEPOOL_LABEL --no-headers | grep $NODE_VERSION_TO_DRAIN | awk '{print $1}')
    echo $NODES >&3
    drain_nodes
elif [[ -f "$SCRIPTDIR/lastrun.txt" && $RETRY == true ]]; then
    printf "%s\n" "${green}Retrying to drain nodes for nodes with label $NODEPOOL_LABEL from lastrun.txt ${end}"
    # get nodes in pool by label count intial ready nodes
    NODES=$(cat $SCRIPTDIR/lastrun.txt)
    drain_nodes
else
    printf "%s\n" "${red}ERROR: Status -- Check for retry file or args something went terrible wrong${end}"
fi

cleanup