#!/usr/bin/env bash
set -euo pipefail

profiles="${1:-crm,pm}"

./scripts/install.sh --profiles "$profiles" --seed
./scripts/conformance.sh
