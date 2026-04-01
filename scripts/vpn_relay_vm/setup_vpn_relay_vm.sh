#!/bin/bash
# ==============================================================================
# setup_vpn_relay_vm.sh
#
# Creates a GCP e2-micro VM that:
#   1. Runs the Docker VPN client container (IKEv2 or L2TP/IPSec)
#   2. Connects to Youngsinc's CLIENT-TO-SITE VPN
#   3. Forwards 0.0.0.0:1433 → 10.0.0.22:1433 inside the tunnel
#
# Cloud Run → VM internal IP:1433 → VPN tunnel → 10.0.0.22:1433 (YISBeta)
#
# WHY A VM and not Cloud Run for the VPN container?
#   Cloud Run is serverless — it does not allow --privileged or NET_ADMIN
#   capabilities required by IPSec (kernel modules, routing table writes).
#   A plain GCP Compute VM has no such restrictions.
#
# USAGE:
#   cp setup_vpn_relay_vm.sh.example setup_vpn_relay_vm.sh   ← gitignored
#   # Fill in credentials below, then:
#   bash setup_vpn_relay_vm.sh
#
# ⚠️  This file is GITIGNORED once renamed — never commit real credentials.
# ==============================================================================
set -euo pipefail

# ── Project config ─────────────────────────────────────────────────────────────
PROJECT="ayra-sales-assistant-490010"
REGION="us-central1"
ZONE="us-central1-a"
VM_NAME="yisbeta-vpn-relay"
MACHINE_TYPE="e2-micro"   # ~$7/month, free-tier eligible
# GCP account username (derived from your Google account, e.g. prasadforshiva@gmail.com → prasadforshiva)
SSH_USER="prasadforshiva"

# ── VPN credentials (client-to-site) ──────────────────────────────────────────
# Fill these in with what Youngsinc gave you.
VPN_SERVER="remote.youngsinc.com"    # VPN server hostname or IP
VPN_PSK='Youngs!5073'               # Pre-Shared Key
VPN_USER="prasadm.3v@youngsinc.com"                   # Username  (L2TP/IPSec client-to-site)
VPN_PASS="prasadm@3V!@"                 # Password  (L2TP/IPSec client-to-site)

# ── SQL Server target ──────────────────────────────────────────────────────────
TARGET_HOST="10.0.0.22"
TARGET_PORT="1433"

# ── Detect VPN mode ───────────────────────────────────────────────────────────
# Set to "ikev2" if Youngsinc gave you only a PSK (site-to-site / IKEv2).
# Set to "l2tp"  if they gave you username + password (client-to-site / L2TP).
VPN_MODE="l2tp"   # L2TP/IPSec with PSK — confirmed

# Repo location inside the VM (will be cloned from GitHub)
REPO_URL="https://github.com/shivaprasadmoka/ayra-sales-assistant"
REPO_DIR="/opt/ayra-sales-assistant"
DOCKER_DIR="${REPO_DIR}/scripts/docker_vpn"

echo "==> [1/6] Creating VPN relay VM: ${VM_NAME} in ${ZONE}..."
gcloud compute instances create "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --machine-type="${MACHINE_TYPE}" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=yisbeta-vpn-relay \
  --scopes=cloud-platform \
  2>/dev/null || echo "VM already exists, continuing..."

echo "==> [2/6] Opening firewall: allow Cloud Run VPC → port 1433 on this VM..."
gcloud compute firewall-rules create allow-yisbeta-relay \
  --project="${PROJECT}" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:1433 \
  --target-tags=yisbeta-vpn-relay \
  --source-ranges=10.8.0.0/28,172.16.0.0/28 \
  --description="Allow Cloud Run VPC connectors to reach VPN SQL relay port" \
  2>/dev/null || echo "Firewall rule already exists, continuing."

echo "==> [3/6] Getting VM internal IP..."
sleep 5
INTERNAL_IP=$(gcloud compute instances describe "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --format="get(networkInterfaces[0].networkIP)")
echo "    Internal IP: ${INTERNAL_IP}"

echo "==> [4/6] Installing Docker + pulling repo on VM..."
gcloud compute ssh "${SSH_USER}@${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="
    set -e
    # Install Docker if not present
    if ! command -v docker &>/dev/null; then
      echo '[vm] Installing Docker...'
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker \$USER || true
    fi

    # Clone or update the repo
    if [ -d '${REPO_DIR}' ]; then
      echo '[vm] Pulling latest repo...'
      cd '${REPO_DIR}' && sudo git pull
    else
      echo '[vm] Cloning repo...'
      sudo git clone '${REPO_URL}' '${REPO_DIR}'
    fi

    echo '[vm] Building VPN Docker image...'
    cd '${DOCKER_DIR}'
    sudo docker build -t youngsinc-vpn-tunnel .
    echo '[vm] Image built successfully.'
  "

echo "==> [5/6] Starting VPN tunnel container on VM..."

# Build the env-var string based on VPN mode
if [ "${VPN_MODE}" = "l2tp" ]; then
  ENV_VARS="-e VPN_SERVER='${VPN_SERVER}' -e VPN_PSK='${VPN_PSK}' -e VPN_USER='${VPN_USER}' -e VPN_PASS='${VPN_PASS}' -e TARGET_HOST='${TARGET_HOST}' -e TARGET_PORT='${TARGET_PORT}'"
else
  ENV_VARS="-e VPN_SERVER='${VPN_SERVER}' -e VPN_PSK='${VPN_PSK}' -e TARGET_HOST='${TARGET_HOST}' -e TARGET_PORT='${TARGET_PORT}'"
fi

gcloud compute ssh "${SSH_USER}@${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="
    set -e
    # Stop existing container if running
    sudo docker rm -f youngsinc-tunnel 2>/dev/null || true

    echo '[vm] Starting VPN tunnel container...'
    sudo docker run -d \
      --name youngsinc-tunnel \
      --network=host \
      --restart=unless-stopped \
      --privileged \
      --cap-add NET_ADMIN \
      --cap-add SYS_MODULE \
      ${ENV_VARS} \
      youngsinc-vpn-tunnel

    echo '[vm] Waiting 30s for VPN to establish...'
    sleep 30
    echo '[vm] Container logs:'
    sudo docker logs youngsinc-tunnel 2>&1 | tail -30

    echo '[vm] Testing port 1433...'
    if nc -z 127.0.0.1 1433 2>/dev/null; then
      echo '[vm] ✅ Port 1433 is open — SQL Server reachable through VPN!'
    else
      echo '[vm] ⚠️  Port 1433 not responding — check logs: sudo docker logs youngsinc-tunnel'
    fi
  "

echo "==> [5b/6] Persisting host-level routing fix (prevents VPN route hijacking Cloud Run replies)..."
gcloud compute ssh "${SSH_USER}@${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="
    set -e
    GATEWAY=\$(ip route show default | awk '/default/ {print \$3; exit}')
    VPC_RANGE='10.8.0.0/28'
    NIC='ens4'

    # Apply immediately
    sudo ip route replace \${VPC_RANGE} via \${GATEWAY} dev \${NIC} 2>/dev/null || true
    echo \"[vm] Route applied: \${VPC_RANGE} via \${GATEWAY} dev \${NIC}\"

    # Persist via rc.local (survives reboots)
    if ! grep -q 'vpn-routing-fix' /etc/rc.local 2>/dev/null; then
      sudo sed -i \"/^exit 0/i # vpn-routing-fix: prevent VPN route from hijacking Cloud Run replies\\nip route replace \${VPC_RANGE} via \${GATEWAY} dev \${NIC} 2>/dev/null || true\" /etc/rc.local
      echo '[vm] rc.local updated.'
    else
      echo '[vm] rc.local already has routing fix, skipping.'
    fi

    # Persist via systemd service (runs after docker starts)
    sudo tee /etc/systemd/system/vpn-routing-fix.service > /dev/null <<SVC
[Unit]
Description=Fix VPN route hijack for Cloud Run VPC connector
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/sbin/ip route replace \${VPC_RANGE} via \${GATEWAY} dev \${NIC}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SVC
    sudo systemctl daemon-reload
    sudo systemctl enable vpn-routing-fix
    sudo systemctl start vpn-routing-fix 2>/dev/null || true
    echo '[vm] Systemd routing fix service enabled.'
  "

echo ""
echo "==> [6/6] Updating connections.json on your local machine..."
# Print the connection block — user should add it to connections.json manually
cat <<CONNBLOCK

Add this entry to connections.json (replace <INTERNAL_IP> with ${INTERNAL_IP}):

{
  "alias": "yisbeta_relay_vm",
  "label": "YIS Beta via Cloud VPN Relay VM",
  "db_type": "mssql",
  "host": "${INTERNAL_IP}",
  "port": 1433,
  "database": "YISBeta",
  "user": "3vAnalysts2",
  "password_secret": "projects/ayra-sales-assistant-490010/secrets/yisbeta-db-password/versions/latest",
  "instance_connection_name": "",
  "allowed_tables": ""
}

Then update Cloud Run env var:
  DB_DEFAULT_ALIAS=yisbeta_relay_vm

CONNBLOCK

echo "======================================================================"
echo "  VPN Relay VM setup complete!"
echo ""
echo "  VM Name      : ${VM_NAME}"
echo "  Internal IP  : ${INTERNAL_IP}   ← use as MSSQL_HOST in Cloud Run"
echo "  SQL port     : 1433"
echo "  VPN mode     : ${VPN_MODE}"
echo ""
echo "  Next steps:"
echo "  1. Update connections.json with alias 'yisbeta_relay_vm' above"
echo "  2. Run: gcloud run services update ayra-sales-assistant \\"
echo "            --region=us-central1 \\"
echo "            --set-env-vars=DB_DEFAULT_ALIAS=yisbeta_relay_vm \\"
echo "            --vpc-connector=ai-factory-connector \\"
echo "            --vpc-egress=private-ranges-only"
echo "  3. Test: send 'How many customers do we have?' to the agent"
echo ""
echo "  To check VPN status later:"
echo "    gcloud compute ssh ${SSH_USER}@${VM_NAME} --zone=${ZONE} --tunnel-through-iap \\"
echo "      --command='sudo docker logs youngsinc-tunnel --tail=50'"
echo "======================================================================"
