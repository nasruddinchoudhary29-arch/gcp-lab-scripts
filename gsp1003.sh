#!/bin/bash
# GSP1003 - Getting Started with Vault

echo "=== Installing Vault CLI ==="
sudo apt-get update -y
sudo apt-get install -y unzip curl
curl -fsSL https://releases.hashicorp.com/vault/1.14.2/vault_1.14.2_linux_amd64.zip -o vault.zip
unzip vault.zip
sudo mv vault /usr/local/bin/
vault --version

echo "=== Starting Vault Dev Server with fixed root token ==="
export VAULT_DEV_ROOT_TOKEN_ID="root"
vault server -dev -dev-root-token-id="$VAULT_DEV_ROOT_TOKEN_ID" > vault.log 2>&1 &
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID"


echo "=== Enabling key/value secrets engine ==="
vault secrets enable -path=secret kv

echo "=== Creating a secret ==="
vault kv put secret/myapp/config username="admin" password="p@ssw0rd"

echo "=== Reading secret back ==="
vault kv get secret/myapp/config

echo "=== Enabling userpass authentication ==="
vault auth enable userpass
vault write auth/userpass/users/testuser password="testpass" policies=default

echo "=== Creating new policy ==="
cat <<EOF | vault policy write mypolicy -
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

echo "=== Creating token with mypolicy ==="
vault token create -policy="mypolicy"

echo "=== Enabling transit secrets engine ==="
vault secrets enable transit

echo "=== Creating encryption key ==="
vault write -f transit/keys/mykey

echo "=== Encrypting sample text ==="
vault write transit/encrypt/mykey plaintext=$(base64 <<< "SensitiveData")

echo "=== Lab setup complete. Vault UI is available at $VAULT_ADDR ==="

