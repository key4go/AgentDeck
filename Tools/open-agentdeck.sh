#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tools/build-app.sh
open "$PWD/.build/SWORAX.app"
