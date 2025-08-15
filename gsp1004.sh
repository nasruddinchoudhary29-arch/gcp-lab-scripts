#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# gsp1004.sh - Hardened script for GSP1003/1004 Vault lab
# - install vault
# - start dev server with random token (printed)
# - prompt user to paste token and validate
# - create secret/hello, save to secret.txt, upload to GCS bucket

info(){ echo ">>> $*"; }
warn(){ echo "!!! $*" >&2; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# ---- detect project ----
info "Detecting GCP project..."
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "unset" ]]; then
  err "No gcloud project set. Run: gcloud config set project <PROJECT_ID>"
fi
info "Project: $PROJECT_ID"

# ---- ensure gsutil available ----
if ! command -v gsutil >/dev/null 2>&1; then
  err "gsutil not found. Cloud Shell should have it. Are you in Cloud Shell?"
fi

# ---- install prerequisites & Vault ----
info "Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y curl gnupg lsb-release unzip || true

# Add HashiCorp apt key & repo (idempotent)
if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
  info "Adding HashiCorp GPG key..."
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
fi
sudo apt-get update -y

if ! command -v vault >/dev/null 2>&1; then
  info "Installing vault via apt..."
  if ! sudo apt-get install -y vault; then
    warn "apt install failed — falling back to binary download"
    VAULT_VER="1.14.2"
    TMPZIP="/tmp/vault_${VAULT_VER}.zip"
    curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_amd64.zip" -o "$TMPZIP"
    unzip -o "$TMPZIP" -d /tmp
    sudo mv /tmp/vault /usr/local/bin/vault
    sudo chmod +x /usr/local/bin/vault
  fi
else
  info "vault present: $(vault --version | head -n1)"
fi

# ---- start Vault dev server if not running ----
export VAULT_ADDR='http://127.0.0.1:8200'
if curl -s --max-time 2 -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" 2>/dev/null | grep -qE '200|429'; then
  info "Vault already responding at $VAULT_ADDR"
else
  # create a random token to show user (they can use this or paste token from logs)
  VAULT_DEV_ROOT_TOKEN_ID="$(openssl rand -hex 12)"
  info "Starting Vault dev server (will use token ID shown below)..."
  info "Dev root token (for convenience): $VAULT_DEV_ROOT_TOKEN_ID"
  # export for server
  export VAULT_DEV_ROOT_TOKEN_ID
  nohup vault server -dev -dev-root-token-id="$VAULT_DEV_ROOT_TOKEN_ID" > vault.log 2>&1 &
  sleep 1
  # wait until responding (timeout 30s)
  COUNT=0
  until curl -s --max-time 2 -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" 2>/dev/null | grep -qE '200|429'; do
    sleep 1
    COUNT=$((COUNT+1))
    if [[ $COUNT -gt 30 ]]; then
      err "Vault did not start within 30s. Check vault.log"
    fi
  done
  info "Vault dev server started and is responding at $VAULT_ADDR"
  info "You can view logs: tail -n 50 vault.log"
fi

# ---- Prompt for token and validate ----
attempts=0
max_attempts=3
VALID=false
echo
echo "==== Vault UI / Token step ===="
echo "Open the Vault UI (Cloud Shell web preview -> Change port -> 8200) or browse to http://127.0.0.1:8200"
echo "You may use the token shown above (or copy the Root Token from vault.log)."
while [[ $attempts -lt $max_attempts ]]; do
  read -r -p "Paste Vault Root Token to use for this session: " INPUT_TOKEN
  export VAULT_TOKEN="$INPUT_TOKEN"
  if vault token lookup >/dev/null 2>&1; then
    VALID=true
    break
  else
    echo "Token invalid or Vault not reachable with that token. Attempts left: $((max_attempts - attempts - 1))"
    attempts=$((attempts+1))
  fi
done
if [[ "$VALID" != true ]]; then
  err "Failed to validate token after $max_attempts attempts. Exiting."
fi
info "Token validated. Continuing..."

# ---- ensure secret/ mount exists (kv v2) ----
info "Ensuring 'secret/' KV v2 mount exists..."
if vault secrets list 2>/dev/null | grep -q '^secret/'; then
  info "secret/ already present"
else
  vault secrets enable -path=secret kv
  info "Enabled secret/ as kv"
fi

# ---- create secret/hello and save to file ----
SECRET_PATH="secret/hello"
SAVED_FILE="secret.txt"
info "Writing secret to $SECRET_PATH"
vault kv put "$SECRET_PATH" value="mysecretvalue"
info "Reading and saving secret value to $SAVED_FILE"
vault kv get -field=value "$SECRET_PATH" > "$SAVED_FILE"

# ---- detect bucket and upload ----
info "Looking for GCS bucket matching project..."
BUCKET=$(gsutil ls 2>/dev/null | grep -m1 "gs://$PROJECT_ID/" || true)
if [[ -n "$BUCKET" ]]; then
  info "Uploading $SAVED_FILE to $BUCKET"
  gsutil cp "$SAVED_FILE" "$BUCKET" || err "gsutil cp failed"
  info "Upload successful: ${BUCKET}$(basename $SAVED_FILE)"
else
  warn "Could not auto-detect bucket 'gs://$PROJECT_ID/'."
  echo "Manually upload the file with:"
  echo "  gsutil cp $SAVED_FILE gs://<your-bucket>/"
fi

# ---- ensure userpass and demo user ----
info "Ensure userpass auth and demo user exist..."
if vault auth list 2>/dev/null | grep -q '^userpass/'; then
  info "userpass already enabled"
else
  vault auth enable userpass
  info "Enabled userpass"
fi

if ! vault list auth/userpass/users 2>/dev/null | grep -q '^testuser$'; then
  vault write auth/userpass/users/testuser password="testpass" policies=default
  info "Created testuser/testpass"
else
  info "testuser already exists"
fi

# ---- ensure transit engine & key ----
info "Ensure transit engine and key 'mykey' exist..."
if vault secrets list 2>/dev/null | grep -q '^transit/'; then
  info "transit present"
else
  vault secrets enable transit
  info "Enabled transit"
fi
if ! vault list transit/keys 2>/dev/null | grep -q '^mykey$'; then
  vault write -f transit/keys/mykey
  info "Created transit key mykey"
else
  info "transit key mykey already exists"
fi

info "Done. Vault UI available at http://127.0.0.1:8200 (use web preview port 8200)."
info "Secret written to: $SAVED_FILE"
