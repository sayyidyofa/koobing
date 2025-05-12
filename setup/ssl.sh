#!/bin/bash
set -euo pipefail

# Ask for basic inputs
read -p "Root CA Common Name: " ROOT_CA_CN
read -p "Kube API Server CN: " APISERVER_CN
read -p "Comma-separated SANs for API Server (e.g. kube.sayyidyofa.me,*.sayyidyofa.me): " APISERVER_SANS
read -p "Front Proxy Client CN: " FRONT_PROXY_CLIENT_CN

# User certs
read -p "Developers CN: " DEV_CN
read -p "Administrators CN: " ADMIN_CN
read -p "System CN: " SYSTEM_CN

# etcd setup
read -p "Root domain (used in etcd discovery, e.g. bongko.id): " ROOT_DOMAIN

OUTDIR=output-certs
[ -d "$OUTDIR" ] && rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

function generate_ca() {
  CN=$1
  OUT=$2
  openssl req -x509 -new -nodes -keyout "$OUTDIR/$OUT.key" -out "$OUTDIR/$OUT.crt" -subj "/CN=$CN" -days 3650
}

function generate_cert() {
  CN=$1
  O=$2
  CA_NAME=$3
  OUT=$4
  SAN=$5

  openssl req -new -nodes -newkey rsa:2048 -keyout "$OUTDIR/$OUT.key" -out "$OUTDIR/$OUT.csr" -subj "/CN=$CN/O=$O"
  echo "subjectAltName=$SAN" > "$OUTDIR/$OUT.ext"
  openssl x509 -req -in "$OUTDIR/$OUT.csr" -CA "$OUTDIR/$CA_NAME.crt" -CAkey "$OUTDIR/$CA_NAME.key" -CAcreateserial -out "$OUTDIR/$OUT.crt" -days 3650 -extfile "$OUTDIR/$OUT.ext"
}

# === Root CAs ===
generate_ca "$ROOT_CA_CN" ca
generate_ca "front-proxy-ca" front-proxy-ca
generate_ca "etcd-ca" etcd-ca

# === API Server TLS ===
generate_cert "$APISERVER_CN" "kubernetes" ca apiserver "DNS:$(echo $APISERVER_SANS | sed 's/,/,DNS:/g')"

# === Front Proxy ===
generate_cert "$FRONT_PROXY_CLIENT_CN" "front-proxy" front-proxy-ca front-proxy-client "DNS:$FRONT_PROXY_CLIENT_CN"

# === User Certs ===
generate_cert "$DEV_CN" developers ca user-developers "DNS:$DEV_CN"
generate_cert "$ADMIN_CN" administrators ca user-administrators "DNS:$ADMIN_CN"
generate_cert "$SYSTEM_CN" system ca user-system "DNS:$SYSTEM_CN"

# === Kubeconfigs ===
function generate_kubeconfig() {
  NAME=$1
  CN=$2

  cat > "$OUTDIR/kubeconfig-$NAME.yaml" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: kubernetes
  cluster:
    server: https://kube.sayyidyofa.me:6443
    certificate-authority: ca.crt
users:
- name: $CN
  user:
    client-certificate: user-$NAME.crt
    client-key: user-$NAME.key
contexts:
- name: $NAME-context
  context:
    cluster: kubernetes
    user: $CN
current-context: $NAME-context
EOF
}

generate_kubeconfig developers "$DEV_CN"
generate_kubeconfig administrators "$ADMIN_CN"
generate_kubeconfig system "$SYSTEM_CN"

# === etcd certs ===
for i in 1 2 3; do
  HOSTNAME=etcd$i
  FQDN="$HOSTNAME.node.homelab.$ROOT_DOMAIN"
  generate_cert "$HOSTNAME" etcd etcd-ca "etcd-server-$HOSTNAME" "DNS:$FQDN,IP:127.0.0.1"
  generate_cert "$HOSTNAME-peer" etcd etcd-ca "etcd-peer-$HOSTNAME" "DNS:$FQDN,IP:127.0.0.1"
done

generate_cert "etcd-client" kube-apiserver etcd-ca etcd-client "DNS:localhost,IP:127.0.0.1"

# === Usage Hints ===
echo -e "\n🔧 Example Component Usage:\n"

echo "🔹 kube-apiserver:"
echo "  --tls-cert-file=$OUTDIR/apiserver.crt"
echo "  --tls-private-key-file=$OUTDIR/apiserver.key"
echo "  --client-ca-file=$OUTDIR/ca.crt"
echo "  --requestheader-client-ca-file=$OUTDIR/front-proxy-ca.crt"
echo "  --requestheader-allowed-names=$FRONT_PROXY_CLIENT_CN"
echo "  --requestheader-username-headers=X-Remote-User"
echo "  --requestheader-group-headers=X-Remote-Group"
echo "  --requestheader-extra-headers-prefix=X-Remote-Extra-"
echo ""

echo "🔹 etcd server:"
echo "  --cert-file=/etc/etcd/pki/etcd-server-<node>.crt"
echo "  --key-file=/etc/etcd/pki/etcd-server-<node>.key"
echo "  --peer-cert-file=/etc/etcd/pki/etcd-peer-<node>.crt"
echo "  --peer-key-file=/etc/etcd/pki/etcd-peer-<node>.key"
echo "  --trusted-ca-file=/etc/etcd/pki/etcd-ca.crt"
echo "  --peer-trusted-ca-file=/etc/etcd/pki/etcd-ca.crt"
echo "  --client-cert-auth --peer-client-cert-auth"
echo ""

echo "🔹 kube-apiserver → etcd client:"
echo "  --etcd-certfile=$OUTDIR/etcd-client.crt"
echo "  --etcd-keyfile=$OUTDIR/etcd-client.key"
echo "  --etcd-cafile=$OUTDIR/etcd-ca.crt"
