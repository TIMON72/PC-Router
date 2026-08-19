#!/usr/bin/env bash
# Установка зависимостей из единого requirements.txt
#   sudo bash scripts/install-deps.sh          # apt
#   bash scripts/install-deps.sh --pip         # pip (ПК / remote)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQ="${REQUIREMENTS_FILE:-$ROOT_DIR/requirements.txt}"
MODE="apt"
[[ "${1:-}" == "--pip" ]] && MODE="pip"

if [[ ! -f "$REQ" ]]; then
  echo "Нет файла: $REQ" >&2
  exit 1
fi

if [[ "$MODE" == "apt" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запустите: sudo bash scripts/install-deps.sh" >&2
    exit 1
  fi
  mapfile -t pkgs < <(sed -n 's/^[[:space:]]*apt:[[:space:]]*//p' "$REQ" | sed '/^$/d')
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    echo "В $REQ нет строк apt:" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${pkgs[@]}"
  echo "OK apt: ${pkgs[*]}"
  exit 0
fi

# pip
mapfile -t pkgs < <(grep -vE '^\s*(#|$|apt:)' "$REQ" | sed 's/[[:space:]]*$//')
if [[ ${#pkgs[@]} -eq 0 ]]; then
  echo "В $REQ нет pip-пакетов" >&2
  exit 1
fi
python3 -m pip install --user "${pkgs[@]}" 2>/dev/null || pip install --user "${pkgs[@]}"
echo "OK pip: ${pkgs[*]}"
