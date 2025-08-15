#!/bin/bash
# GSP1004 - Vault Secret Upload

echo "=== Installing Vault CLI ==="
sudo apt-get update -y
sudo apt-get install -y unzip curl
curl -fsSL https://releases.hashicorp.com/vault/1.14.2/vault_1.14.2_linux_amd64.zip -o vault.zip
unzip -o vault.zip
sudo mv vault /usr/local/bin/
vault --version

# Generate random root token for dev mode
VAULT_DEV_ROOT_TOKEN_ID="$(openssl rand -hex 16)"
export VAULT_ADDR='http://127.0.0.1:8200'

echo "=== Starting Vault Dev Server ==="
vault server -dev -dev-root-token-id="$VAULT_DEV_ROOT_TOKEN_ID" > vault.log 2>&1 &

sleep 5
echo
echo "======================================="
echo "Vault UI: http://127.0.0.1:8200"
echo "Root Token (from logs): $VAULT_DEV_ROOT_TOKEN_ID"
echo "======================================="
echo
read -p "Paste your Vault root token here: " VAULT_TOKEN
export VAULT_TOKEN

echo "=== Enabling kv secrets engine if not already ==="
if ! vault secrets list -format=json | grep -q '"secret/"'; then
  vault secrets enable -path=secret kv
fi

echo "=== Creating 'secret/hello' ==="
vault kv put secret/hello value="mysecretvalue"

echo "=== Saving secret to file ==="
vault kv get -field=value secret/hello > secret.txt

PROJECT_ID=$(gcloud config get-value project)
echo "=== Uploading to GCS bucket ==="
gsutil cp secret.txt "gs://$PROJECT_ID/"

echo "=== Done! Check the lab UI for completion. ==="
