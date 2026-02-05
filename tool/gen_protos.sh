#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/lib/core/proto"
PROTO_DIR="${ROOT}/../core_lib/src/proto_src"

mkdir -p "${OUT_DIR}"

if ! command -v protoc-gen-dart >/dev/null 2>&1; then
  echo "protoc-gen-dart not found. Run:" >&2
  echo "  /home/maks/apps/flutter/bin/dart pub global activate protoc_plugin" >&2
  echo "and ensure ~/.pub-cache/bin is on PATH." >&2
  exit 1
fi

protoc \
  --proto_path="${PROTO_DIR}" \
  --dart_out="${OUT_DIR}" \
  "${PROTO_DIR}"/wire_format.proto \
  "${PROTO_DIR}"/ukey.proto \
  "${PROTO_DIR}"/securemessage.proto \
  "${PROTO_DIR}"/securegcm.proto \
  "${PROTO_DIR}"/offline_wire_formats.proto \
  "${PROTO_DIR}"/device_to_device_messages.proto

echo "Generated Dart protos in ${OUT_DIR}"
