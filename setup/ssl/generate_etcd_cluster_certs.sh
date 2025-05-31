#!/bin/bash
set -eo pipefail # Exit on error, treat unset vars as error, propagate pipeline errors

# Script to automatically generate certificates for a 3-node etcd cluster
# using the generate_certs.sh script.

# --- Configuration ---
GENERATOR_SCRIPT_NAME="generate_certs.sh"
CA_CERT_FILENAME="ca.crt"
CA_KEY_FILENAME="ca.key"
CA_SERIAL_FILENAME="ca.srl" # Assumed to be next to CA cert/key or default used by generator
OUTPUT_DIR="etcd_cluster_certs"
NUM_ETCD_NODES=3

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# --- Main Script Logic ---

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GENERATOR_SCRIPT_PATH="${SCRIPT_DIR}/${GENERATOR_SCRIPT_NAME}"
TARGET_OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"

log_info "Starting etcd cluster certificate generation..."
log_info "Using generator script: ${GENERATOR_SCRIPT_PATH}"
log_info "CA certificate: ${SCRIPT_DIR}/${CA_CERT_FILENAME}"
log_info "CA key: ${SCRIPT_DIR}/${CA_KEY_FILENAME}"
log_info "Output directory for etcd certs: ${TARGET_OUTPUT_DIR}"

# 1. Check Prerequisites
if [ ! -f "$GENERATOR_SCRIPT_PATH" ]; then
    log_error "Generator script '${GENERATOR_SCRIPT_NAME}' not found in '${SCRIPT_DIR}'."
    exit 1
fi
if [ ! -x "$GENERATOR_SCRIPT_PATH" ]; then
    log_error "Generator script '${GENERATOR_SCRIPT_PATH}' is not executable. Please run 'chmod +x ${GENERATOR_SCRIPT_PATH}'."
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/${CA_CERT_FILENAME}" ]; then
    log_error "CA certificate '${CA_CERT_FILENAME}' not found in '${SCRIPT_DIR}'."
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/${CA_KEY_FILENAME}" ]; then
    log_error "CA key '${CA_KEY_FILENAME}' not found in '${SCRIPT_DIR}'."
    exit 1
fi
# Note: We'll let generate_certs.sh handle ca.srl existence or creation with its default.

# 2. Setup Output Directory
log_info "Setting up output directory: ${TARGET_OUTPUT_DIR}"
if [ -d "$TARGET_OUTPUT_DIR" ]; then
    log_info "Removing existing output directory..."
    rm -rf "$TARGET_OUTPUT_DIR"
fi
mkdir -p "$TARGET_OUTPUT_DIR"
log_info "Output directory created."

# 3. Loop and Generate Certificates for each etcd node
for i in $(seq 1 "$NUM_ETCD_NODES"); do
    NODE_NUM="$i"
    NODE_PREFIX="etcd${NODE_NUM}"
    NODE_CN="etcd${NODE_NUM}.bongko.id"
    # DNS SANs: etcdX.node.homelab.bongko.id, etcdX.node.bongko.id, etcd.service.bongko.id, etcd-client-ssl.service.bongko.id, etcd-server-ssl.service.bongko.id
    NODE_DNS_SANS="etcd${NODE_NUM}.node.homelab.bongko.id,etcd${NODE_NUM}.node.bongko.id,etcd.service.bongko.id,etcd-client-ssl.service.bongko.id,etcd-server-ssl.service.bongko.id"
    NODE_IP_SANS="192.168.1.11${NODE_NUM}" # generate_certs.sh will add 127.0.0.1 automatically

    log_info "Generating certificates for ${NODE_PREFIX} (CN: ${NODE_CN})..."

    # Prepare inputs for generate_certs.sh
    # Paths to CA files are relative to TARGET_OUTPUT_DIR because we cd into it.
    # generate_certs.sh defaults for algo and validity are used by providing empty lines.
    INPUTS=$(cat <<EOF
y
../${CA_CERT_FILENAME}
../${CA_KEY_FILENAME}
../${CA_SERIAL_FILENAME}
2
\n
${NODE_PREFIX}
${NODE_CN}
${NODE_DNS_SANS}
${NODE_IP_SANS}
\n
EOF
)

    # Execute generate_certs.sh from within the target output directory
    (
        cd "$TARGET_OUTPUT_DIR" || exit 1
        echo -e "${INPUTS}" | "$GENERATOR_SCRIPT_PATH"
        if [ $? -ne 0 ]; then
            log_error "Failed to generate certificates for ${NODE_PREFIX}."
            # Consider exiting the main script or just logging and continuing
            exit 1 # Exit if any node cert generation fails
        fi
    )
    log_info "Successfully generated certificates for ${NODE_PREFIX} in ${TARGET_OUTPUT_DIR}/${NODE_PREFIX}.*"
done

log_info "-----------------------------------------------------"
log_info "Etcd cluster certificate generation complete!"
log_info "All certificates are located in: ${TARGET_OUTPUT_DIR}"
log_info "-----------------------------------------------------"

exit 0
