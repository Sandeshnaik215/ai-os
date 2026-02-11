#!/bin/bash

MODEL="$1"
PHY_THREADS=$(nproc)

LLAMA_BIN=$(command -v llama-bench)

if [ -z "$LLAMA_BIN" ]; then
    echo "Error: llama-bench not found in PATH"
    exit 1
fi

$LLAMA_BIN -m "$MODEL" -p 512 -n 128 -t "$PHY_THREADS"
