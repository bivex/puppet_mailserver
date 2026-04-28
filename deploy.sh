#!/bin/bash
# Deploy mail server to Parallels Ubuntu VM
# Usage: ./deploy.sh

VM="ubuntu-x86"
VM_USER="parallels"  # поменяй на своего юзера в VM
DOMAIN="${1:-example.com}"

echo "==> Installing Puppet in VM..."
prlctl exec "$VM" -- sudo apt update
prlctl exec "$VM" -- sudo apt install -y puppet

echo "==> Copying PuppetCode to VM..."
prlctl exec "$VM" -- mkdir -p /tmp/PuppetCode
# Используем prlctl exec с cat для передачи файла
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cat "${SCRIPT_DIR}/mailserver.pp" | prlctl exec "$VM" -- sudo tee /tmp/PuppetCode/mailserver.pp > /dev/null

echo "==> Applying Puppet manifest (domain: $DOMAIN)..."
prlctl exec "$VM" -- "sudo sed -i 's/example.com/${DOMAIN}/g' /tmp/PuppetCode/mailserver.pp"
prlctl exec "$VM" -- sudo puppet apply /tmp/PuppetCode/mailserver.pp

echo "==> Creating test mail user..."
prlctl exec "$VM" -- sudo useradd -m -s /bin/bash mailuser 2>/dev/null || true
prlctl exec "$VM" -- "echo 'mailuser:password123' | sudo chpasswd"
prlctl exec "$VM" -- "sudo -u mailuser mkdir -p /home/mailuser/Maildir"

echo ""
echo "==> Done! Mail server is ready."
echo "    SMTP:  port 25 / 587 (TLS)"
echo "    IMAP:  port 143 / 993 (SSL)"
echo "    POP3:  port 110 / 995 (SSL)"
echo "    User:  mailuser / password123"
echo ""
echo "==> Test sending mail:"
echo "    echo 'Hello' | mail -s 'Test' mailuser"
