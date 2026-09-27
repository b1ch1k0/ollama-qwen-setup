#!/usr/bin/env bash
# Reproduces the tuned Qwen3.8-27B-Uncensored Ollama setup (160K context, MTP, q8_0 KV cache).
# Usage: sudo bash setup-qwen-160k.sh                (auto-picks context from GPU VRAM)
#        curl -fsSL <raw-url> | sudo bash            (run straight from the internet)
#        curl -fsSL <raw-url> | sudo NUM_CTX=65536 bash   (force a context size)
set -euo pipefail

BASE_MODEL="bichiko/qwen-uncensored-160k"
NEW_MODEL="qwen-uncensored-160k"
DROPIN_DIR=/etc/systemd/system/ollama.service.d
DROPIN_FILE="$DROPIN_DIR/20-qwen-tuning.conf"
MIN_OLLAMA="0.17.1"

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

# 1. GPU check
command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Install the NVIDIA driver first and reboot."
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
log "GPU: $GPU_NAME (${VRAM_MB} MiB)"

# 2. Pick context size (values measured on a 24GB TITAN RTX with q8_0 KV + MTP)
if [[ -z "${NUM_CTX:-}" ]]; then
  if   (( VRAM_MB >= 23000 )); then NUM_CTX=163840
  elif (( VRAM_MB >= 20000 )); then NUM_CTX=65536
  else die "Only ${VRAM_MB} MiB VRAM. This 17GB model needs a 24GB GPU (or set NUM_CTX manually and accept CPU offload)."
  fi
fi
log "Context: $NUM_CTX tokens"

# 3. Install Ollama if missing
if ! command -v ollama >/dev/null; then
  log "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ "$(printf '%s\n%s\n' "$MIN_OLLAMA" "$OLLAMA_VER" | sort -V | head -1)" != "$MIN_OLLAMA" ]]; then
  log "Ollama $OLLAMA_VER is too old (need >= $MIN_OLLAMA). Updating..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
log "Ollama version: $(ollama --version)"

# 4. Server tuning (global: applies to all models)
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<'EOF'
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF
log "Wrote $DROPIN_FILE"
systemctl daemon-reload
systemctl enable ollama >/dev/null 2>&1 || true
systemctl restart ollama
for _ in $(seq 1 30); do curl -sf http://localhost:11434/api/version >/dev/null && break; sleep 1; done
curl -sf http://localhost:11434/api/version >/dev/null || die "Ollama server did not start. Check: journalctl -u ollama"

# 5. Pull base model (~18GB)
log "Pulling $BASE_MODEL (skipped if already present)..."
ollama pull "$BASE_MODEL"

# 6. The pulled model already has num_ctx 163840 + MTP + num_gpu 99; only rebuild if a smaller context is needed
if [[ "$NUM_CTX" == "163840" ]]; then
  ollama cp "$BASE_MODEL" "$NEW_MODEL"
else
  MODELFILE=$(mktemp)
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$BASE_MODEL" "$NUM_CTX" > "$MODELFILE"
  ollama create "$NEW_MODEL" -f "$MODELFILE"
  rm -f "$MODELFILE"
fi

# 7. Verify: load, generate, check it is 100% on GPU
log "Verifying (first load takes ~30-60s)..."
RESP=$(curl -s http://localhost:11434/api/generate \
  -d "{\"model\":\"$NEW_MODEL\",\"prompt\":\"Write three sentences about mountains.\",\"stream\":false,\"think\":false,\"options\":{\"num_predict\":200}}")
TPS=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(round(d['eval_count']/(d['eval_duration']/1e9),1))" 2>/dev/null || echo "?")
PS_LINE=$(ollama ps | grep "$NEW_MODEL" || true)
echo
echo "$PS_LINE"
if [[ "$PS_LINE" == *"100% GPU"* ]]; then
  log "OK: $NEW_MODEL runs 100% on GPU at ${TPS} tok/s with ${NUM_CTX} context."
else
  warn "Model is not fully on GPU (or failed to load). Speed: ${TPS} tok/s."
  warn "Try a smaller context: re-run with NUM_CTX=131072 (e.g. sudo NUM_CTX=131072 bash <script>)"
fi
echo
echo "Run it with:  ollama run $NEW_MODEL"
