#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation shutdown test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It stops kubelet service, kills all containers on each node, kills all pods,
# disables chronyd service on each node and on the machine itself, sets date ahead 400days
# then starts kubelet on each node and waits for cluster recovery. This simulates
# cert-rotation after 1 year.
# TODO: Run suite of conformance tests after recovery
cat >"${SHARED_DIR}"/time-skew-test.sh <<'EOF'
#!/bin/bash

set -euxo pipefail
sudo systemctl stop chronyd

SKEW=${1:-90d}
OC=${OC:-oc}
SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
COMMAND_TIMEOUT=15m

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  export KUBECONFIG=$(find "$KUBECONFIG" -type f | head -n 1)
fi

source /usr/local/share/cert-rotation-functions.sh

# Mask chrony service on all nodes and set time on guests
run-on-all-nodes "systemctl mask chronyd --now && sudo timedatectl set-time +${SKEW}"

# Set kubelet node IP hint. Nodes are created with two interfaces - provisioning and external,
# and we want to make sure kubelet uses external address as main, instead of DHCP racing to use
# a random one as primary
run-on-all-nodes "echo 'KUBELET_NODEIP_HINT=192.168.127.1' | sudo tee /etc/default/nodeip-configuration"

run-on-first-master "echo -n \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\" > /var/cluster-shutdown-time"
# Shutdown nodes
mapfile -d ' ' -t VMS < <( virsh list --all --name )
set +x
for vm in ${VMS[@]}; do
  if [[ "${vm}" == "minikube" ]]; then
    continue
  fi
  virsh shutdown ${vm}
done
for vm in ${VMS[@]}; do
  if [[ "${vm}" == "minikube" ]]; then
    continue
  fi
  until virsh domstate ${vm} | grep "shut off"; do
    sleep 10
  done | /usr/local/bin/tqdm --desc "Shutting down ${vm} VM" --null
done



# Set date for host
sudo timedatectl status
sudo timedatectl set-time +${SKEW}
sudo timedatectl status

# Start nodes again
for vm in ${VMS[@]}; do
  if [[ "${vm}" == "minikube" ]]; then
    continue
  fi
  virsh start ${vm}
done
for vm in ${VMS[@]}; do
  if [[ "${vm}" == "minikube" ]]; then
    continue
  fi
  until virsh domstate ${vm} | grep "running"; do
    sleep 10
  done | /usr/local/bin/tqdm --desc "Starting ${vm} VM" --null
done
set -x

# Check that time on nodes has been updated
until run-on-all-nodes "timedatectl status"; do sleep 30; done

# Restart kubelet
run-on-all-nodes "systemctl restart kubelet"

pod-restart-workarounds

# Wait for nodes to become unready and approve CSRs until nodes are ready again
wait-for-nodes-to-be-ready

# Wait for kube-apiserver operator to generate new lb-ext kubeconfig
wait-for-valid-lb-ext-kubeconfig

# Wait for kube-apiserver to become Progressing to avoid stale operator status
wait-for-kubeapiserver-to-start-progressing

# Wait for operators to finish updates
wait-for-operators-to-stabilize
EOF
chmod +x "${SHARED_DIR}"/time-skew-test.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/time-skew-test.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
  -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' \
	"root@${IP}" \
	/usr/local/bin/time-skew-test.sh \
	${SKEW}
