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

# O catalogo nao e recurso do bundle porque, na Free Edition com Default
# Storage habilitado, a API do Unity Catalog exige um MANAGED LOCATION que a
# conta gratuita nao oferece (400 INVALID_STATE). A criacao por SQL funciona.
databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS lakehouse COMMENT 'Catalogo governado da plataforma de dados da concessionaria'" \
  --profile "$profile"
