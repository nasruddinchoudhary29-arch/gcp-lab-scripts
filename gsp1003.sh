#!/bin/bash
# GSP1003 - Getting Started with Vault

echo "=== Starting Vault Dev Server ==="
vault server -dev > vault.log 2>&1 &
sleep 5

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="root"

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

echo "=== Script completed. You can now use Vault UI at: $VAULT_ADDR ==="
