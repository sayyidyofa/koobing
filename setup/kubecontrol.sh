#!/bin/bash
#
# A script to configure a HA Kubernetes cluster using HAProxy and CoreDNS.
# This script is idempotent, resetting nodes before configuration.

set -e

# --- Configuration Variables ---
# --- Component Versions ---
KUBE_VERSION="1.34.0"
CILIUM_VERSION="1.16.2"

# --- SSH Configuration ---
SSH_USER="sayyidyofa"
SSH_KEY_PATH="$HOME/.ssh/id_rsa-lazynuc"

# --- Network Configuration ---
DOMAIN="k8s.bongko.id"
# The VIP of your dedicated Service Tier (CoreDNS/HAProxy)
SERVICE_VIP="192.168.1.100"
POD_CIDR="10.244.0.0/16"
NODE_INTERFACE="eth0" 

# --- VM Definitions ---
declare -A vms
# Structure: "ID;NAME;IP;ROLE"
vms[0]="231;master1;192.168.1.231;master"
vms[1]="232;master2;192.168.1.232;master"
vms[2]="233;master3;192.168.1.233;master"
vms[3]="241;worker1;192.168.1.241;worker"
vms[4]="242;worker2;192.168.1.242;worker"
vms[5]="243;worker3;192.168.1.243;worker"

# --- Pre-flight SSH Test Function ---
test_ssh_connections() {
    echo "---"
    echo "🔬 Running Pre-flight SSH Connection Tests..."
    local all_connections_ok=true
    while IFS=';' read -r _ VM_NAME IP_ADDR _; do
        echo -n "  -> Testing connection to ${VM_NAME} (${IP_ADDR})... "
        if ssh -n -i ${SSH_KEY_PATH} -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${SSH_USER}@${IP_ADDR} 'exit' &>/dev/null; then
            echo "✅ OK"
        else
            echo "❌ FAILED"
            all_connections_ok=false
        fi
    done < <(printf "%s\n" "${vms[@]}")

    if [ "$all_connections_ok" = false ]; then
        echo "❌ One or more VMs are not reachable via SSH. Please check their status and network configuration. Aborting."
        exit 1
    fi
    echo "✅ All nodes are reachable."
}


# --- Main Execution ---
echo "Kubernetes Node Configuration Script (K8s: v${KUBE_VERSION}, CNI: Cilium)"
echo "----------------------------------------------------------------------"
read -p "⚠️  This will configure the 6 pre-existing VMs. Are you sure? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# --- Phase 1: Pre-flight Checks ---
test_ssh_connections

# --- Phase 2: Install Bastion Tools & Generate Certificates ---
echo "---"
echo "🔧 Installing tools on bastion (Fedora) and generating certificates..."
if [[ ! -f "ca.pem" || ! -f "ca-key.pem" ]]; then echo "❌ CA files not found. Aborting."; exit 1; fi
if [ ! -f "$SSH_KEY_PATH" ]; then echo "❌ SSH key not found. Aborting."; exit 1; fi
sudo dnf install -y cfssl openssl kubeadm kubectl
mkdir -p certs
cd certs
echo '{"CN":"kubernetes","key":{"algo":"rsa","size":2048}}' | cfssl genkey - | cfssljson -bare ca-config
echo '{"signing":{"default":{"expiry":"8760h"},"profiles":{"kubernetes":{"usages":["signing","key encipherment","server auth","client auth"],"expiry":"8760h"}}}}' > ca-config.json
echo '{"CN":"kube-apiserver","key":{"algo":"rsa","size":2048}}' | cfssl genkey - | cfssljson -bare kube-apiserver
cfssl sign -ca ../ca.pem -ca-key ../ca-key.pem -config ca-config.json -profile kubernetes -hostname "127.0.0.1,${SERVICE_VIP},api.${DOMAIN},master1.${DOMAIN},master2.${DOMAIN},master3.${DOMAIN},192.168.1.231,192.168.1.232,192.168.1.233,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.default.svc.cluster.local" kube-apiserver.csr | cfssljson -bare kube-apiserver
echo '{"CN":"etcd","key":{"algo":"rsa","size":2048}}' | cfssl genkey - | cfssljson -bare etcd-server
cfssl sign -ca ../ca.pem -ca-key ../ca-key.pem -config ca-config.json -profile kubernetes -hostname "127.0.0.1,master1.${DOMAIN},master2.${DOMAIN},master3.${DOMAIN},192.168.1.231,192.168.1.232,192.168.1.233" etcd-server.csr | cfssljson -bare etcd-server
echo '{"key":{"algo":"rsa","size":2048}}' | cfssl genkey - | cfssljson -bare service-account-temp
mv service-account-temp-key.pem service-account-key.pem
openssl rsa -in service-account-key.pem -pubout -out service-account.pem
rm service-account-temp.csr
echo "--> Copying root CA into certs bundle..."
cp ../ca.pem .
cp ../ca-key.pem .
cd ..
echo "✅ Certificates generated in ./certs/ directory."

# --- Phase 3: Generate Kubeadm Config ---
echo "---"
echo "📝 Generating Kubeadm configuration file..."
KUBE_MAJOR_MINOR=$(echo "${KUBE_VERSION}" | cut -d. -f1,2)
MASTER1_IP=$(echo "${vms[0]}" | cut -d';' -f3)

mkdir -p configs
cat <<EOF > ./configs/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
uploadCerts: true
certificateKey: $(kubeadm certs certificate-key)
localAPIEndpoint:
  advertiseAddress: "${MASTER1_IP}"
  bindPort: 6443
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${KUBE_VERSION}
controlPlaneEndpoint: "api.${DOMAIN}:6443"
networking:
  podSubnet: "${POD_CIDR}"
apiServer:
  certSANs:
  - "${SERVICE_VIP}"
  - "api.${DOMAIN}"
etcd:
  local:
    serverCertSANs:
      - "master1.${DOMAIN}"
      - "master2.${DOMAIN}"
      - "master3.${DOMAIN}"
    peerCertSANs:
      - "master1.${DOMAIN}"
      - "master2.${DOMAIN}"
      - "master3.${DOMAIN}"
      - "192.168.1.231"
      - "192.168.1.232"
      - "192.168.1.233"
EOF
echo "✅ Kubeadm config generated."

# --- Phase 4: Configure Nodes ---
echo "---"
echo "🚀 Configuring all nodes (Ubuntu)..."
while IFS=';' read -r VM_ID VM_NAME IP_ADDR ROLE; do
    echo "---"
    echo "Configuring node ${VM_NAME} (${IP_ADDR})..."
    
    scp -i ${SSH_KEY_PATH} -r ./certs ${SSH_USER}@${IP_ADDR}:~/

    ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${IP_ADDR} << EOF
        set -ex
        
        echo "--> Resetting any previous kubeadm state..."
        sudo kubeadm reset -f || true
        echo "--> Purging related packages..."
        sudo apt-get purge -y --allow-change-held-packages kubelet kubeadm kubectl keepalived haproxy || true
        echo "--> Removing leftover configuration files..."
        sudo rm -rf /etc/kubernetes /var/lib/etcd

        echo "--> Configuring node..."
        sudo hostnamectl set-hostname ${VM_NAME}.${DOMAIN}
        
        # NOTE: DNS is assumed to be manually configured on all cluster nodes.
        
        echo "--> Enabling kernel modules and settings..."
        sudo modprobe br_netfilter
        echo 'net.bridge.bridge-nf-call-iptables = 1' | sudo tee /etc/sysctl.d/98-kubernetes-cri.conf > /dev/null
        echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf > /dev/null
        sudo sysctl --system
        
        echo "--> Installing packages..."
        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg containerd crun
        
        echo "--> Disabling UFW firewall..."
        sudo ufw disable || true
        
        echo "--> Generating full containerd config and setting SystemdCgroup to true..."
        sudo mkdir -p /etc/containerd
        sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
        sudo systemctl restart containerd

        echo "--> Installing Kubernetes components..."
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/deb/Release.key | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y kubelet=${KUBE_VERSION}-* kubeadm=${KUBE_VERSION}-* kubectl=${KUBE_VERSION}-*
        sudo apt-mark hold kubelet kubeadm kubectl
        sudo systemctl enable --now containerd

        if [ "${ROLE}" == "master" ]; then
            echo "--> Placing certificates for master node..."
            sudo mkdir -p /etc/kubernetes/pki/etcd
            sudo cp ~/certs/* /etc/kubernetes/pki/
            sudo cp ~/certs/etcd-server.pem /etc/kubernetes/pki/etcd/server.pem
            sudo cp ~/certs/etcd-server-key.pem /etc/kubernetes/pki/etcd/server-key.pem
            sudo cp ~/certs/ca.pem /etc/kubernetes/pki/etcd/ca.pem
        fi

        echo "--> Cleaning up staged files..."
        rm -rf ~/certs
EOF
done < <(printf "%s\n" "${vms[@]}")

# --- Phase 5: Initialize Cluster and Join Nodes ---
echo "---"
echo "Initializing cluster on master1..."
scp -i ${SSH_KEY_PATH} ./configs/kubeadm-config.yaml ${SSH_USER}@${MASTER1_IP}:~/
ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${MASTER1_IP} "sudo mkdir -p /etc/kubernetes && sudo cp ~/kubeadm-config.yaml /etc/kubeadm-config.yaml && rm ~/kubeadm-config.yaml"

INIT_OUTPUT_FILE="init_output.log"
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@${MASTER1_IP} "sudo kubeadm init --config=/etc/kubeadm-config.yaml --upload-certs" | tee "${INIT_OUTPUT_FILE}"

# Use robust Python one-liners to parse credentials.
echo "--> Parsing join commands from init output using Python..."
JOIN_TOKEN=$(cat ${INIT_OUTPUT_FILE} | python3 -c "import sys; data = sys.stdin.read().replace(' \\\n', ' ').split(); print(data[data.index('--token') + 1])")
JOIN_HASH=$(cat ${INIT_OUTPUT_FILE} | python3 -c "import sys; data = sys.stdin.read().replace(' \\\n', ' ').split(); print(data[data.index('--discovery-token-ca-cert-hash') + 1])")
JOIN_CERT_KEY=$(cat ${INIT_OUTPUT_FILE} | python3 -c "import sys; data = sys.stdin.read().replace(' \\\n', ' ').split(); print(data[data.index('--certificate-key') + 1])")

if [ -z "${JOIN_TOKEN}" ] || [ -z "${JOIN_HASH}" ] || [ -z "${JOIN_CERT_KEY}" ]; then
    echo "❌ Failed to parse join credentials from kubeadm init output. Aborting."
    cat "${INIT_OUTPUT_FILE}"
    exit 1
fi

MASTER_JOIN_CMD="kubeadm join api.${DOMAIN}:6443 --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${JOIN_HASH} --control-plane --certificate-key ${JOIN_CERT_KEY}"
WORKER_JOIN_CMD="kubeadm join api.${DOMAIN}:6443 --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${JOIN_HASH}"

echo "Joining other masters to the cluster..."
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@192.168.1.232 "sudo ${MASTER_JOIN_CMD}"
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@192.168.1.233 "sudo ${MASTER_JOIN_CMD}"

echo "Joining worker nodes to the cluster..."
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@192.168.1.241 "sudo ${WORKER_JOIN_CMD}"
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@192.168.1.242 "sudo ${WORKER_JOIN_CMD}"
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@192.168.1.243 "sudo ${WORKER_JOIN_CMD}"

echo "✅ All nodes have joined the cluster."
rm "${INIT_OUTPUT_FILE}"

# --- Phase 6: Automated Cluster Verification & CNI Installation ---
echo ""
echo "⏳ Finalizing cluster setup..."
echo "-> Installing Helm on bastion..."
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm ./get_helm.sh

echo "-> Retrieving kubeconfig from master1..."
# **THE FINAL FIX**: Use ssh with 'sudo cat' to read the protected admin.conf file.
ssh -n -i ${SSH_KEY_PATH} ${SSH_USER}@${MASTER1_IP} "sudo cat /etc/kubernetes/admin.conf" > ./config
chown $(id -u):$(id -g) ./config

echo "-> Installing Cilium CNI..."
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version ${CILIUM_VERSION} --namespace kube-system --set kubeProxyReplacement=strict --set ipam.mode=kubernetes --kubeconfig=./config
echo "✅ Cilium installation initiated."
echo "-> Waiting for all 6 nodes to be Ready..."
while true; do
    READY_NODES=$(kubectl --kubeconfig=./config get nodes 2>/dev/null | grep -c " Ready" || true)
    if [ "$READY_NODES" -eq 6 ]; then
        echo ""
        echo "✅ All 6 nodes are Ready."
        break
    fi
    echo -n "."
    sleep 10
done

# --- Phase 7: Final Instructions ---
echo ""
echo "🎉 Cluster deployment complete and verified!"
echo "-------------------------------------------------------------------------------------"
echo "Your Kubernetes cluster is ready. You can manage it using the 'config' file in this directory."
echo ""
echo "To check the status, run:"
echo "    kubectl --kubeconfig=./config get nodes -o wide"
echo ""
echo "Enjoy your new Kubernetes cluster!"
