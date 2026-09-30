#!/usr/bin/env bash
set -euo pipefail

matlab_bin="${MATLAB_BIN:-/usr/local/MATLAB/R2024a/bin/matlab}"
nvidia_tls_lib="${NVIDIA_TLS_LIB:-}"
if [[ -z "$nvidia_tls_lib" ]]; then
    nvidia_tls_lib="$(ldconfig -p | awk '/libnvidia-tls\.so\.[0-9]/{if (path == "") path = $NF} END {print path}')"
fi

nvidia_icd="${NVIDIA_ICD:-/usr/share/vulkan/icd.d/nvidia_icd.json}"
if [[ ! -x "$matlab_bin" ]]; then
    printf 'MATLAB executable not found: %s\n' "$matlab_bin" >&2
    exit 1
fi
if [[ -z "$nvidia_tls_lib" || ! -f "$nvidia_tls_lib" ]]; then
    printf 'NVIDIA TLS library not found. Set NVIDIA_TLS_LIB explicitly.\n' >&2
    exit 1
fi
if [[ ! -f "$nvidia_icd" ]]; then
    printf 'NVIDIA Vulkan ICD manifest not found: %s\n' "$nvidia_icd" >&2
    exit 1
fi

exec env \
    LD_PRELOAD="$nvidia_tls_lib${LD_PRELOAD:+:$LD_PRELOAD}" \
    VK_ICD_FILENAMES="$nvidia_icd" \
    VK_LOADER_LAYERS_DISABLE='~implicit' \
    "$matlab_bin" -batch "addpath('scripts'); benchmarkFieldIIEkhos"