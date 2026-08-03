#!/usr/bin/env bash
#
# Верификация исходников развёрнутых контрактов на BscScan.
#
# Верификация — не косметика. Пока исходники не опубликованы, держатель не может проверить, что в
# сети лежит именно тот контракт, который прошёл аудит: он видит только байткод. Для аудитора это
# ещё и способ убедиться, что развёрнута та самая версия, которую он читал.
#
# Требуется ключ BscScan API (бесплатный, на счёте BscScan):
#   export BSCSCAN_API_KEY=...
#
# Аргументы конструктора должны совпадать с теми, что ушли при развёртывании, байт в байт —
# иначе BscScan откажет. Они берутся из broadcast/Deploy.s.sol/<chainId>/run-latest.json.
#
# Использование:
#   ./script/verify.sh testnet
#   ./script/verify.sh mainnet

set -euo pipefail

NETWORK="${1:-testnet}"

case "$NETWORK" in
  testnet)
    CHAIN_ID=97
    IDENTITY_REGISTRY=0x3838f73f9787f8b4f8a1e0173de7c7030a570806
    ALLOWLIST=0x5f1586bDaCD7bbD6da2E8EB377C51A268afd40D2
    TOKEN=0xdDedDC32271975c30856948E1e9dCaD31C548c90
    ;;
  mainnet)
    CHAIN_ID=56
    echo "Боевые адреса не заполнены: развёртывание в mainnet — только после внешнего аудита (A5)." >&2
    exit 1
    ;;
  *)
    echo "Неизвестная сеть: $NETWORK (ожидается testnet или mainnet)" >&2
    exit 1
    ;;
esac

if [[ -z "${BSCSCAN_API_KEY:-}" ]]; then
  echo "BSCSCAN_API_KEY не задан. Ключ бесплатный: https://bscscan.com/myapikey" >&2
  exit 1
fi

RUN_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
if [[ ! -f "$RUN_FILE" ]]; then
  echo "Нет записи развёртывания: $RUN_FILE" >&2
  echo "Верифицировать нечего — сначала разверните контракты этим же деревом исходников." >&2
  exit 1
fi

# Аргументы читаются из записи развёртывания, а не набираются руками: параметры выпуска (имя,
# maxSupply, propertyId, адрес админа) у каждого выпуска свои, и опечатка здесь выглядит как
# «исходники не совпали», а не как опечатка. Читаются построчно, потому что имя выпуска содержит
# пробелы — разбиение по словам склеило бы его неправильно.
args_of() {
  jq -r --arg name "$1" \
    '.transactions[] | select(.contractName == $name and .transactionType == "CREATE")
     | .arguments // [] | .[]' \
    "$RUN_FILE"
}

verify() {
  local address="$1" path="$2" name="$3" ctor_args="${4:-}"

  echo "→ $name @ $address"
  if [[ -n "$ctor_args" ]]; then
    forge verify-contract \
      --chain-id "$CHAIN_ID" \
      --etherscan-api-key "$BSCSCAN_API_KEY" \
      --watch \
      --constructor-args "$ctor_args" \
      "$address" "$path:$name"
  else
    forge verify-contract \
      --chain-id "$CHAIN_ID" \
      --etherscan-api-key "$BSCSCAN_API_KEY" \
      --watch \
      "$address" "$path:$name"
  fi
}

encode() {
  local signature="$1"
  shift
  cast abi-encode "$signature" "$@"
}

echo "Верификация в сети $NETWORK (chain id $CHAIN_ID)"

# IdentityRegistry принимает адрес распорядителя; Allowlist — ничего.
# read -a вместо mapfile: mapfile появился в bash 4, а системный bash в macOS — 3.2.
REGISTRY_ARGS=()
while IFS= read -r line; do REGISTRY_ARGS+=("$line"); done < <(args_of IdentityRegistry)
verify "$IDENTITY_REGISTRY" src/IdentityRegistry.sol IdentityRegistry \
  "$(encode 'constructor(address)' "${REGISTRY_ARGS[@]}")"

verify "$ALLOWLIST" src/Allowlist.sol Allowlist

TOKEN_ARGS=()
while IFS= read -r line; do TOKEN_ARGS+=("$line"); done < <(args_of AtriaPropertyToken)
if [[ ${#TOKEN_ARGS[@]} -ne 7 ]]; then
  echo "Ожидалось 7 аргументов конструктора токена, прочитано ${#TOKEN_ARGS[@]} из $RUN_FILE" >&2
  exit 1
fi

verify "$TOKEN" src/AtriaPropertyToken.sol AtriaPropertyToken \
  "$(encode 'constructor(string,string,address,uint256,bytes32,string,address)' "${TOKEN_ARGS[@]}")"

echo "Готово. Проверьте вкладку Contract на BscScan: исходники должны отображаться без предупреждений."
