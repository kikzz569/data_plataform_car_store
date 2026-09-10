#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Uso: $0 <profile>" >&2
  exit 64
fi

profile="$1"

if ! command -v databricks >/dev/null 2>&1; then
  echo "Erro: Databricks CLI nao encontrado no PATH." >&2
  exit 127
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
raw_dir="$(CDPATH= cd -- "$script_dir/../../raw" && pwd)"

erp_file="erp_concessionaria_2024_2025.csv"
crm_file="crm_concessionaria_2024_2025.csv"
estoque_file="estoque_concessionaria_2024_2025.csv"

for filename in "$erp_file" "$crm_file" "$estoque_file"; do
  if [[ ! -s "$raw_dir/$filename" ]]; then
    echo "Erro: arquivo obrigatorio ausente ou vazio: $raw_dir/$filename" >&2
    exit 1
  fi
done

staging_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir/erp" "$staging_dir/crm" "$staging_dir/loja"
cp -- "$raw_dir/$erp_file" "$staging_dir/erp/"
cp -- "$raw_dir/$crm_file" "$staging_dir/crm/"
cp -- "$raw_dir/$estoque_file" "$staging_dir/loja/"

for sistema in erp crm loja; do
  destino="dbfs:/Volumes/lakehouse/bronze/raw/$sistema"
  databricks fs mkdirs "$destino" --profile "$profile"
  databricks fs cp "$staging_dir/$sistema" "$destino" \
    --recursive \
    --overwrite \
    --profile "$profile"
done

echo "Arquivos raw enviados para dbfs:/Volumes/lakehouse/bronze/raw."
