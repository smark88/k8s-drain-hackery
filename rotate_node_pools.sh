#!/bin/bash
set -o errexit -o pipefail -o nounset

# global vars
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
PROJECTDIR=`pwd`
UNSCHEDULEABLE="false"

# drain vars
NODEPOOL_LABEL="awslabeler.influxdata.com/type=compute"
NODE_VERSION_TO_DRAIN="1.18.20"
REGION="us-east-1"

# defaults
INITIAL_NODE_COUNT=0
nodeErrorCode=0
drainErrorCode=0

# list of namespaces that should not be on a drained node
NODE_ACTIVE_NAMESPACES=(argo-events argo-observer argocd argowf cert-manager cloudability cluster-autoscaler computation external-dns functionsd glance ingress iox istio-operator istio-system kafka-operator keda kube-node-lease kube-public kvmigrate newrelic-minion notebooksd ops pinneditemsd pipescope reboot-coordinator sampleappd sealed-secrets telegraf-operator twodotoh vault vault-secrets-manager velero)


## Process
# 1. set nodepool via label and region
# 2. login to aws cli
# 3. run script

## Script process/ordering
# 1. drains single node from nodepool
# 2. checks drained node is unschduleable and has no actively used namespaces on it
# 3. terminate the drained node
#       a. check node has been deleted before continuing
#       b. check it has been replaced by new node before continuing
# 4. repeat step 1 for next node

drain_nodes() {
    printf "Draining nodes for nodes with label $NODEPOOL_LABEL\n"
    # get nodes in pool by label count intial ready nodes
    for i in $(kubectl get node -l $NODEPOOL_LABEL --no-headers | grep $NODE_VERSION_TO_DRAIN | awk '{print $1}'); do 
    kubectl drain $i --delete-emptydir-data  --ignore-daemonsets --as=admin
    sleep 5
    # double drain as its cheap insurence and should happen quick the second time
    kubectl drain $i --delete-emptydir-data  --ignore-daemonsets --as=admin
    # check second drain exit status if non 0 exit
    drainErrorCode=$?
    if [ $drainErrorCode -ne 0 ]; then
        printf "kubectl drain node command exited with non 0"
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
        printf "node is unschedulable"
        printf "check for active namespaces on node $1\n"
        NODEDESCRIPTION=$(kubectl describe node $1)
        # check for namespace from exclusion list
        for a in ${NODE_ACTIVE_NAMESPACES[@]}; do
        if [[ $NODEDESCRIPTION == *"$a"* ]]; then
            printf "Namespace $a present on node check -- FAIL\n"
            exit 1
        fi
        done
    else     
        printf "node should be unschedulable if it was drained" 
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
        printf "terminating node: $NODE via aws cli"
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
                printf "k8 Node Name: $K8_NODE_NAME EC2 Node Name: $NODE has been terminated\n"
            else 
                printf "pause 15s while k8 Node Name: $K8_NODE_NAME EC2 Node Name: $NODE is being terminated\n"
                sleep 15
                check_termination
            fi
        }
        check_termination
        # recursive shit function to check new node is up before proceeding to avoid racing condition
        check_node_count () {
            # grep -v to exclude "NotReady"
            CURRENT_NODE_COUNT=$(kubectl get node -l $NODEPOOL_LABEL --no-headers | grep -v NotReady | grep Ready | wc -l)  
            if [ $CURRENT_NODE_COUNT -eq $INITIAL_NODE_COUNT ]; then
                printf "Continuing new node is up\n"
            else 
                printf "pause 15s wait for new node to be deployed\n"
                sleep 15
                check_node_count
            fi
         
        }
        check_node_count
    else
        printf "node should be unschedulable for ec2 termination" 
        exit 1
    fi
}

drain_nodes
