#!/usr/bin/env bash
# Installs Ollama on the server and pulls a model. Ollama keeps its default
# settings, except for listening on the private network.
#
#     ./ollama.sh qwen2.5:0.5b
set -euo pipefail
source "$(dirname "$0")/config.sh"

model=${1:-qwen2.5:0.5b}
read -r _ _ public _ _ < <(nodes server)

on "$public" "curl -fsSL https://ollama.com/install.sh | sudo sh > /dev/null 2>&1
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  printf '[Service]\nEnvironment=OLLAMA_HOST=0.0.0.0:11434\n' | sudo tee /etc/systemd/system/ollama.service.d/listen.conf > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart ollama
  until curl -s localhost:11434/api/tags > /dev/null; do sleep 1; done
  ollama pull $model > /dev/null 2>&1
  ollama --version
  ollama list"
