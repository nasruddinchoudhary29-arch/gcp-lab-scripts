#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# GSP1003 — Getting Started with Vault
# - auto-detect project and bucket
# - install Vault (apt preferred, fallback to zip)
# - start Vault dev server with fixed root token
# - idempotent checks for mounts/auth
# - write secret/hello -> secret.txt -> upload to GCS
# - prompts user when UI interaction is required

# ---- Config ----
export VAULT_DEV_ROOT_TOKEN_ID="$(openssl rand -hex 16)"
SCRIPT_NAME="$(basename "$0")"

# ---- Helpers ----
info(){ echo ">>> $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }
prompt_continue(){
  echo
  echo "==== ACTION REQUIRED (UI) ===="
  echo "$1"
  echo "When done, press Enter to continue..."
  read -r _
}

# ---- 0. project + bucket detection ----
info "Detecting GCP project..."
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "unset" ]]; then
  err "No gcloud project set. Run: gcloud config set project <PROJECT_ID>"
fi
info "Project ID: $PROJECT_ID"

# try to discover the pre-created bucket (common pattern: gs://${PROJECT_ID}/)
info "Detecting GCS bucket..."
BUCKET=$(gsutil ls 2>/dev/null | grep -m1 "gs://$PROJECT_ID" || true)
if [[ -z "$BUCKET" ]]; then
  # fallback: take first bucket
  BUCKET=$(gsutil ls 2>/dev/null | head -n1 || true)
fi
if [[ -z "$BUCKET" ]]; then
  echo "No GCS bucket found in this project. Please create or provide a bucket name."
  echo "To continue manually, run: gsutil cp secret.txt gs://<your-bucket>/"
  GOT_BUCKET=""
else
  GOT_BUCKET="$BUCKET"
  info "Using bucket: $GOT_BUCKET"
fi

# ---- 1. Install Vault (apt method preferred) ----
info "Installing Vault (apt repository preferred)..."
sudo apt update -y
sudo apt install -y curl gnupg lsb-release unzip || true

# Add HashiCorp apt key & repo (idempotent)
if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
fi
sudo apt-get update -y
if ! command -v vault >/dev/null 2>&1; then
  if sudo apt-get install -y vault; then
    info "Installed vault via apt."
  else
    info "apt install failed — falling back to zip binary download."
    VAULT_VER="1.14.2"
    curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_amd64.zip" -o /tmp/vault.zip
    unzip -o /tmp/vault.zip -d /tmp
    sudo mv /tmp/vault /usr/local/bin/vault
    chmod +x /usr/local/bin/vault
  fi
else
  info "vault already installed: $(vault --version | head -n1)"
fi

# ---- 2. Start Vault dev server with fixed token (idempotent) ----
# If a vault process is already running on 127.0.0.1:8200, reuse it.
if curl --silent --max-time 2 http://127.0.0.1:8200/v1/sys/health >/dev/null 2>&1; then
  info "Vault is already listening on http://127.0.0.1:8200 — assuming running dev server."
else
  info "Starting Vault dev server with fixed root token: $VAULT_DEV_TOKEN"
  export VAULT_DEV_ROOT_TOKEN_ID="$VAULT_DEV_TOKEN"
  nohup vault server -dev -dev-root-token-id="$VAULT_DEV_ROOT_TOKEN_ID" > vault.log 2>&1 &
  sleep 4
fi

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="$VAULT_DEV_TOKEN"

# quick status check
if ! vault status >/dev/null 2>&1; then
  err "Vault not responding. Check vault.log"
fi
info "Vault running and authenticated with token: $VAULT_TOKEN"

# ---- 3. Enable kv at secret/ if missing (idempotent) ----
info "Ensuring KV engine mounted at 'secret/' (kv v2)..."
if ! vault secrets list -format=json | jq -r 'keys[]' 2>/dev/null | grep -q '^secret/'; then
  vault secrets enable -path=secret kv
  info "Enabled secret/ kv-v2"
else
  info "secret/ already mounted — skipping enable"
fi

# ---- 4. Create secret/hello and export to file ----
SECRET_PATH="secret/hello"
SAVED_FILE="secret.txt"
info "Writing sample secret to $SECRET_PATH"
vault kv put "$SECRET_PATH" value="mysecretvalue" >/dev/null

info "Reading secret value and saving to $SAVED_FILE"
vault kv get -field=value "$SECRET_PATH" > "$SAVED_FILE"
info "Saved secret value to $SAVED_FILE (lines: $(wc -l < "$SAVED_FILE"))"

# ---- 5. Upload to GCS (auto-detected bucket) ----
if [[ -n "${GOT_BUCKET:-}" ]]; then
  info "Uploading $SAVED_FILE to $GOT_BUCKET"
  gsutil cp "$SAVED_FILE" "$GOT_BUCKET" || err "gsutil upload failed"
  info "Uploaded. You can verify with: gsutil ls ${GOT_BUCKET} | grep $(basename $SAVED_FILE)"
else
  echo
  echo "=== Manual step required: upload secret.txt to a GCS bucket ==="
  echo "No suitable bucket detected automatically."
  echo "Run this command to upload:"
  echo "  gsutil cp $SAVED_FILE gs://<your-bucket>/"
  echo
fi

# ---- 6. Create userpass demo user (idempotent) ----
info "Ensuring userpass auth enabled and demo user exists..."
if ! vault auth list -format=json | jq -r 'keys[]' 2>/dev/null | grep -q '^userpass/'; then
  vault auth enable userpass
  info "Enabled userpass"
else
  info "userpass already enabled"
fi

# create demo user if not present
if ! vault list auth/userpass/users >/dev/null 2>&1 || ! vault list auth/userpass/users 2>/dev/null | grep -q '^testuser$'; then
  vault write auth/userpass/users/testuser password="testpass" policies=default >/dev/null
  info "Created userpass user: testuser / testpass"
else
  info "testuser already exists"
fi

# ---- 7. Make transit key if missing ----
info "Ensuring transit engine and key exist..."
if ! vault secrets list -format=json | jq -r 'keys[]' 2>/dev/null | grep -q '^transit/'; then
  vault secrets enable transit
fi
if ! vault list transit/keys >/dev/null 2>&1 || ! vault list transit/keys 2>/dev/null | grep -q '^mykey$'; then
  vault write -f transit/keys/mykey >/dev/null
  info "Created transit key mykey"
else
  info "transit key mykey already exists"
fi

info "All done. Vault UI is available via Cloud Shell web preview on port 8200 (preview -> change port -> 8200)."
info "Root token: $VAULT_TOKEN"
info "Secret saved to: $SAVED_FILE and uploaded to: ${GOT_BUCKET:-<not uploaded>}"

