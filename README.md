# ollama-qwen-setup

One-command setup of [`bichiko/qwen-uncensored-160k`](https://ollama.com/bichiko/qwen-uncensored-160k) for Ollama. It is Qwen3.8-27B-Uncensored (q4_K_M) with a 160K context, MTP speculative decoding, and every layer on the GPU.

```bash
curl -fsSL https://raw.githubusercontent.com/b1ch1k0/ollama-qwen-setup/main/setup-qwen-160k.sh | sudo bash
```

Requirements: an NVIDIA GPU with 24 GB VRAM and the driver already installed.

## What it does

1. Installs or updates Ollama.
2. Sets `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, which are server-wide. The model will not load at 160K without them.
3. Pulls `bichiko/qwen-uncensored-160k` and checks that it runs 100% on the GPU.

Measured on a TITAN RTX 24 GB: about 42 tok/s at 160K context. Before tuning it managed about 6 tok/s at 128K.

A q4_0 KV cache would allow 256K, but it noticeably degrades Georgian text, so this setup uses q8_0.

## Options

```bash
curl -fsSL <url> | sudo NUM_CTX=65536 bash   # force a smaller context
```
