#!/bin/bash
set -o errexit -o pipefail -o nounset
declare -a NODE_ACTIVE_NAMESPACES
NODE_ACTIVE_NAMESPACES+=(argo-events argo-observer argocd argowf cert-manager cloudability cluster-autoscaler computation external-dns functionsd glance ingress iox)
NODE_ACTIVE_NAMESPACES+=(istio-operator istio-system kafka-operator keda kube-node-lease kube-public kvmigrate newrelic-minion notebooksd ops pinneditemsd pipescope)
NODE_ACTIVE_NAMESPACES+=(sampleappd sealed-secrets telegraf-operator twodotoh vault vault-secrets-manager velero)

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
tmpfile=$(mktemp $SCRIPTDIR/test.txt)
exec 3>"$tmpfile"
#NODES=$(cat $SCRIPTDIR/lastrun.txt)
NODES=$(kubectl get node -l awslabeler.influxdata.com/type=highmem --no-headers | awk '{print $1}')
printf "$NODES\n" >&3