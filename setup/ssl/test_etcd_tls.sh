#!/bin/bash
set -eo pipefail # Exit on error, treat unset vars as error, propagate pipeline errors

_INITIAL_PWD="$(pwd)" # Store initial PWD for resolving relative paths

# --- Configuration ---
GENERATOR_SCRIPT_PATH="./generate_certs.sh" # Path to your cert generator script

# Resolve GENERATOR_SCRIPT_PATH to an absolute path
if [[ "$GENERATOR_SCRIPT_PATH" != /* ]]; then
    # If it's relative, make it absolute based on the initial PWD
    GENERATOR_SCRIPT_PATH="${_INITIAL_PWD}/${GENERATOR_SCRIPT_PATH}"
fi

TEST_DIR_NAME="etcd_test_workspace"
CERTS_SUBDIR="certs"
COMPOSE_FILE_NAME="docker-compose.yml"
ETCD_IMAGE="gcr.io/etcd-development/etcd:v3.5.14" # Specify a recent etcd version

# Docker network and IP configuration
DOCKER_NET_NAME="etcd_tls_test_net"
DOCKER_NET_SUBNET="172.20.0.0/24"
ETCD0_IP="172.20.0.10"
ETCD1_IP="172.20.0.11"
ETCD2_IP="172.20.0.12"
ETCD0_PEER_PORT="2380"
ETCD1_PEER_PORT="2380"
ETCD2_PEER_PORT="2380"
ETCD0_CLIENT_PORT="2379"
ETCD1_CLIENT_PORT="2379"
ETCD2_CLIENT_PORT="2379"
HOST_ETCD0_CLIENT_PORT="2379"

# Full paths
TEST_DIR="${_INITIAL_PWD}/${TEST_DIR_NAME}"
CERTS_DIR="${TEST_DIR}/${CERTS_SUBDIR}"
COMPOSE_FILE_PATH="${TEST_DIR}/${COMPOSE_FILE_NAME}"

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    if [ ! -f "$GENERATOR_SCRIPT_PATH" ] || [ ! -x "$GENERATOR_SCRIPT_PATH" ]; then
        log_error "Certificate generator script ($GENERATOR_SCRIPT_PATH) not found or not executable."
        exit 1
    fi
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker."
        exit 1
    fi
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null ; then
        log_error "Docker Compose (v1 or v2 plugin) is not installed. Please install it."
        exit 1
    fi
     if ! command -v curl &> /dev/null; then
        log_error "curl is not installed. Please install curl."
        exit 1
    fi
    log_info "Prerequisites met."
}

setup_workspace() {
    log_info "Setting up test workspace: $TEST_DIR"
    if [ -d "$TEST_DIR" ]; then
        log_info "Removing existing test directory: $TEST_DIR"
        rm -rf "$TEST_DIR"
    fi
    mkdir -p "$CERTS_DIR"
    log_info "Workspace created."
}

call_cert_generator() {
    local cert_name="$1"
    shift
    local inputs="$@"
    
    log_info "Generating $cert_name certificates..."
    (
        cd "$CERTS_DIR" || exit 1
        echo -e "$inputs" | "$GENERATOR_SCRIPT_PATH"
        if [ $? -ne 0 ]; then
            log_error "Failed to generate $cert_name certificates. Current dir: $(pwd). Generator path: $GENERATOR_SCRIPT_PATH"
            exit 1
        fi
    )
    log_info "$cert_name certificates generated successfully in $CERTS_DIR."
}

generate_all_certificates() {
    log_info "Starting certificate generation process..."

    # 1. Generate CA and a dummy follow-up cert to consume all prompts from generate_certs.sh
    local ca_inputs="n\nTest ETCD CA\nTest Org\nUS\n\n\ndummypfx_after_ca\ndummycn_after_ca\n\n\n\n"
    call_cert_generator "CA and dummy follow-up cert" "$ca_inputs"

    local common_cert_inputs_prefix="y\n./ca.crt\n./ca.key\n./ca.srl"
    local default_algo="1" # RSA 2048
    local default_validity="730" # days

    # 2. Generate etcd0 server/peer cert (mTLS)
    local etcd0_prefix="etcd0"
    local etcd0_cn="etcd0.local"
    local etcd0_dns_sans="etcd0.local,localhost"
    local etcd0_ip_sans="${ETCD0_IP},127.0.0.1"
    # Inputs: Have CA?, CA paths, Purpose (mTLS=2), Algo, Output prefix, CN, DNS SANs, IP SANs, Validity
    local etcd0_inputs="${common_cert_inputs_prefix}\n2\n${default_algo}\n${etcd0_prefix}\n${etcd0_cn}\n${etcd0_dns_sans}\n${etcd0_ip_sans}\n${default_validity}"
    call_cert_generator "etcd0" "$etcd0_inputs"

    # 3. Generate etcd1 server/peer cert (mTLS)
    local etcd1_prefix="etcd1"
    local etcd1_cn="etcd1.local"
    local etcd1_dns_sans="etcd1.local,localhost"
    local etcd1_ip_sans="${ETCD1_IP},127.0.0.1"
    local etcd1_inputs="${common_cert_inputs_prefix}\n2\n${default_algo}\n${etcd1_prefix}\n${etcd1_cn}\n${etcd1_dns_sans}\n${etcd1_ip_sans}\n${default_validity}"
    call_cert_generator "etcd1" "$etcd1_inputs"

    # 4. Generate etcd2 server/peer cert (mTLS)
    local etcd2_prefix="etcd2"
    local etcd2_cn="etcd2.local"
    local etcd2_dns_sans="etcd2.local,localhost"
    local etcd2_ip_sans="${ETCD2_IP},127.0.0.1"
    local etcd2_inputs="${common_cert_inputs_prefix}\n2\n${default_algo}\n${etcd2_prefix}\n${etcd2_cn}\n${etcd2_dns_sans}\n${etcd2_ip_sans}\n${default_validity}"
    call_cert_generator "etcd2" "$etcd2_inputs"

    # 5. Generate etcd-client cert (Client Auth Only, Machine)
    local client_prefix="etcd-client"
    local client_cn="etcd-client.local" # This will be the CN for the client cert
    local client_dns_sans="etcd-client.local,localhost"
    local client_ip_sans="127.0.0.1"
    # Corrected order of inputs:
    # Have CA?, CA paths, Purpose (Client Auth=3), Algo, Output prefix, Is Machine? (y), CN, DNS SANs, IP SANs, Validity
    local client_inputs="${common_cert_inputs_prefix}\n3\n${default_algo}\n${client_prefix}\ny\n${client_cn}\n${client_dns_sans}\n${client_ip_sans}\n${default_validity}"
    call_cert_generator "etcd-client" "$client_inputs"

    log_info "All certificates generated."
}

create_docker_compose_yaml() {
    log_info "Creating Docker Compose file: $COMPOSE_FILE_PATH"
    cat > "$COMPOSE_FILE_PATH" <<-EOF
version: '3.8' # This version is informational for Compose V2+; can be removed if desired

networks:
  ${DOCKER_NET_NAME}:
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_NET_SUBNET}

services:
  etcd0:
    image: ${ETCD_IMAGE}
    container_name: etcd0
    hostname: etcd0.local
    networks:
      ${DOCKER_NET_NAME}:
        ipv4_address: ${ETCD0_IP}
    ports:
      - "${HOST_ETCD0_CLIENT_PORT}:${ETCD0_CLIENT_PORT}"
    volumes:
      - ./${CERTS_SUBDIR}:/etc/etcd/certs:ro
      - etcd0-data:/etcd-data
    command: >
      etcd
      --name=etcd0
      --data-dir=/etcd-data
      --listen-client-urls=https://0.0.0.0:${ETCD0_CLIENT_PORT}
      --advertise-client-urls=https://${ETCD0_IP}:${ETCD0_CLIENT_PORT}
      --listen-peer-urls=https://0.0.0.0:${ETCD0_PEER_PORT}
      --initial-advertise-peer-urls=https://${ETCD0_IP}:${ETCD0_PEER_PORT}
      --initial-cluster=etcd0=https://${ETCD0_IP}:${ETCD0_PEER_PORT},etcd1=https://${ETCD1_IP}:${ETCD1_PEER_PORT},etcd2=https://${ETCD2_IP}:${ETCD2_PEER_PORT}
      --initial-cluster-token=etcd-tls-test-cluster
      --initial-cluster-state=new
      --client-cert-auth=true
      --trusted-ca-file=/etc/etcd/certs/ca.crt
      --cert-file=/etc/etcd/certs/etcd0.crt
      --key-file=/etc/etcd/certs/etcd0.key
      --peer-client-cert-auth=true
      --peer-trusted-ca-file=/etc/etcd/certs/ca.crt
      --peer-cert-file=/etc/etcd/certs/etcd0.crt
      --peer-key-file=/etc/etcd/certs/etcd0.key
      --auto-compaction-retention=1
      --logger=zap --log-outputs=stderr

  etcd1:
    image: ${ETCD_IMAGE}
    container_name: etcd1
    hostname: etcd1.local
    networks:
      ${DOCKER_NET_NAME}:
        ipv4_address: ${ETCD1_IP}
    volumes:
      - ./${CERTS_SUBDIR}:/etc/etcd/certs:ro
      - etcd1-data:/etcd-data
    command: >
      etcd
      --name=etcd1
      --data-dir=/etcd-data
      --listen-client-urls=https://0.0.0.0:${ETCD1_CLIENT_PORT}
      --advertise-client-urls=https://${ETCD1_IP}:${ETCD1_CLIENT_PORT}
      --listen-peer-urls=https://0.0.0.0:${ETCD1_PEER_PORT}
      --initial-advertise-peer-urls=https://${ETCD1_IP}:${ETCD1_PEER_PORT}
      --initial-cluster=etcd0=https://${ETCD0_IP}:${ETCD0_PEER_PORT},etcd1=https://${ETCD1_IP}:${ETCD1_PEER_PORT},etcd2=https://${ETCD2_IP}:${ETCD2_PEER_PORT}
      --initial-cluster-token=etcd-tls-test-cluster
      --initial-cluster-state=new
      --client-cert-auth=true
      --trusted-ca-file=/etc/etcd/certs/ca.crt
      --cert-file=/etc/etcd/certs/etcd1.crt
      --key-file=/etc/etcd/certs/etcd1.key
      --peer-client-cert-auth=true
      --peer-trusted-ca-file=/etc/etcd/certs/ca.crt
      --peer-cert-file=/etc/etcd/certs/etcd1.crt
      --peer-key-file=/etc/etcd/certs/etcd1.key
      --auto-compaction-retention=1
      --logger=zap --log-outputs=stderr

  etcd2:
    image: ${ETCD_IMAGE}
    container_name: etcd2
    hostname: etcd2.local
    networks:
      ${DOCKER_NET_NAME}:
        ipv4_address: ${ETCD2_IP}
    volumes:
      - ./${CERTS_SUBDIR}:/etc/etcd/certs:ro
      - etcd2-data:/etcd-data
    command: >
      etcd
      --name=etcd2
      --data-dir=/etcd-data
      --listen-client-urls=https://0.0.0.0:${ETCD2_CLIENT_PORT}
      --advertise-client-urls=https://${ETCD2_IP}:${ETCD2_CLIENT_PORT}
      --listen-peer-urls=https://0.0.0.0:${ETCD2_PEER_PORT}
      --initial-advertise-peer-urls=https://${ETCD2_IP}:${ETCD2_PEER_PORT}
      --initial-cluster=etcd0=https://${ETCD0_IP}:${ETCD0_PEER_PORT},etcd1=https://${ETCD1_IP}:${ETCD1_PEER_PORT},etcd2=https://${ETCD2_IP}:${ETCD2_PEER_PORT}
      --initial-cluster-token=etcd-tls-test-cluster
      --initial-cluster-state=new
      --client-cert-auth=true
      --trusted-ca-file=/etc/etcd/certs/ca.crt
      --cert-file=/etc/etcd/certs/etcd2.crt
      --key-file=/etc/etcd/certs/etcd2.key
      --peer-client-cert-auth=true
      --peer-trusted-ca-file=/etc/etcd/certs/ca.crt
      --peer-cert-file=/etc/etcd/certs/etcd2.crt
      --peer-key-file=/etc/etcd/certs/etcd2.key
      --auto-compaction-retention=1
      --logger=zap --log-outputs=stderr

volumes:
  etcd0-data:
  etcd1-data:
  etcd2-data:
EOF
    log_info "Docker Compose file created."
}

get_docker_compose_cmd() {
    if docker compose version &> /dev/null; then
        echo "docker compose"
    elif command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        log_error "Cannot find docker-compose or 'docker compose' plugin."
        exit 1
    fi
}

start_etcd_cluster() {
    local docker_compose_cmd
    docker_compose_cmd=$(get_docker_compose_cmd)

    log_info "Starting etcd cluster using Docker Compose..."
    (
        cd "$TEST_DIR" || exit 1
        $docker_compose_cmd up -d --remove-orphans
    )
    if [ $? -ne 0 ]; then
        log_error "Failed to start etcd cluster."
        (cd "$TEST_DIR" && $docker_compose_cmd logs)
        exit 1
    fi
    log_info "etcd cluster started. Waiting for it to stabilize (approx 30 seconds)..."
    sleep 30
}

test_cluster_health() {
    log_info "Testing etcd cluster health (peer communication)..."
    # Define the arguments for etcdctl
    local etcdctl_args="--endpoints https://127.0.0.1:${ETCD0_CLIENT_PORT} \
        --cacert /etc/etcd/certs/ca.crt \
        --cert /etc/etcd/certs/etcd0.crt \
        --key /etc/etcd/certs/etcd0.key \
        endpoint health --cluster -w table"

    # Path to etcdctl inside the container
    local etcdctl_path_in_container="/usr/local/bin/etcdctl"

    log_info "Executing: docker exec -e ETCDCTL_API=3 etcd0 $etcdctl_path_in_container $etcdctl_args"
    # Execute etcdctl directly, passing ETCDCTL_API=3 as an environment variable
    if ! docker exec -e ETCDCTL_API=3 etcd0 $etcdctl_path_in_container $etcdctl_args; then
        log_error "Cluster health check failed. Dumping etcd0 logs:"
        docker logs etcd0
        log_error "Dumping etcd1 logs:"
        docker logs etcd1
        log_error "Dumping etcd2 logs:"
        docker logs etcd2
        return 1 # Failure
    fi
    log_info "Cluster health check PASSED."
    return 0 # Success
}

test_client_access() {
    log_info "Testing client access to etcd cluster using dedicated client certificate..."
    local client_target_endpoint="https://127.0.0.1:${HOST_ETCD0_CLIENT_PORT}"

    log_info "Testing with curl: $client_target_endpoint/health"
    local curl_output
    if ! curl_output=$(curl --silent --show-error --cacert "${CERTS_DIR}/ca.crt" \
            --cert "${CERTS_DIR}/etcd-client.crt" \
            --key "${CERTS_DIR}/etcd-client.key" \
            "$client_target_endpoint/health"); then
        log_error "curl to /health failed."
        log_info "Curl output: $curl_output"
        return 1
    fi
    log_info "Curl /health response: $curl_output"
    if ! echo "$curl_output" | grep -q '"health":"true"'; then
         if ! echo "$curl_output" | grep -q '"health":true'; then
            log_error "Unexpected /health response from curl: $curl_output"
            return 1
        fi
    fi
    log_info "curl /health test PASSED."

    if command -v etcdctl &> /dev/null; then
        log_info "etcdctl found on host. Testing put/get..."
        local test_key="tls_test_key_$(date +%s)"
        local test_val="hello_secure_etcd"

        log_info "Executing etcdctl put $test_key $test_val"
        if ! ETCDCTL_API=3 etcdctl --endpoints "$client_target_endpoint" \
                --cacert "${CERTS_DIR}/ca.crt" \
                --cert "${CERTS_DIR}/etcd-client.crt" \
                --key "${CERTS_DIR}/etcd-client.key" \
                put "$test_key" "$test_val"; then
            log_error "etcdctl put failed."
            return 1
        fi
        log_info "etcdctl put successful."

        log_info "Executing etcdctl get $test_key"
        local get_output
        if ! get_output=$(ETCDCTL_API=3 etcdctl --endpoints "$client_target_endpoint" \
                --cacert "${CERTS_DIR}/ca.crt" \
                --cert "${CERTS_DIR}/etcd-client.crt" \
                --key "${CERTS_DIR}/etcd-client.key" \
                get "$test_key" -w simple); then
            log_error "etcdctl get failed."
            return 1
        fi
        log_info "etcdctl get output: $get_output"
        local expected_get_output="${test_key}\n${test_val}"
        if [[ "$get_output" != "$expected_get_output" ]]; then
            log_error "etcdctl get returned unexpected value. Expected: '$expected_get_output', Got: '$get_output'"
            return 1
        fi
        log_info "etcdctl get successful and value matches."
        log_info "etcdctl put/get test PASSED."
    else
        log_info "etcdctl not found on host. Skipping etcdctl put/get test. Curl test was sufficient for basic client auth."
    fi

    log_info "Client access test PASSED."
    return 0
}

stop_and_cleanup_docker() {
    local docker_compose_cmd
    docker_compose_cmd=$(get_docker_compose_cmd)

    log_info "Stopping and cleaning up etcd cluster Docker environment..."
    if [ -f "$COMPOSE_FILE_PATH" ]; then
        (
            cd "$TEST_DIR" || exit 1
            $docker_compose_cmd down -v --remove-orphans
        )
        if [ $? -ne 0 ]; then
            log_error "Failed to cleanly stop Docker Compose services."
        else
            log_info "Docker Compose services stopped and volumes removed."
        fi
    else
        log_info "Docker Compose file not found, skipping docker cleanup."
    fi

    if docker network inspect "$DOCKER_NET_NAME" &> /dev/null; then
        log_info "Removing Docker network: $DOCKER_NET_NAME"
        if ! docker network rm "$DOCKER_NET_NAME"; then
            log_info "Could not remove network $DOCKER_NET_NAME. It might still be in use or already removed."
        fi
    fi
}

cleanup_workspace() {
    log_info "Cleaning up test workspace: $TEST_DIR"
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
        log_info "Test workspace removed."
    fi
}

# --- Main Execution ---
main() {
    trap '{ stop_and_cleanup_docker; cleanup_workspace; log_info "Test script finished."; }' EXIT SIGINT SIGTERM

    check_prerequisites
    setup_workspace
    generate_all_certificates
    create_docker_compose_yaml
    start_etcd_cluster

    local overall_test_passed=true

    if ! test_cluster_health; then
        log_error "Cluster health test FAILED."
        overall_test_passed=false
    fi

    if $overall_test_passed; then
        if ! test_client_access; then
            log_error "Client access test FAILED."
            overall_test_passed=false
        fi
    fi

    echo
    if $overall_test_passed; then
        log_info "*********************"
        log_info "*** ALL TESTS PASSED ***"
        log_info "*********************"
    else
        log_error "!!!!!!!!!!!!!!!!!!!!!!"
        log_error "!!! SOME TESTS FAILED !!!"
        log_error "!!!!!!!!!!!!!!!!!!!!!!"
        exit 1
    fi
    exit 0
}

main "$@"
