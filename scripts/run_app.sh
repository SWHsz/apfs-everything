#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$ROOT/dist/APFSFind.app" ]] || bash "$ROOT/scripts/build_app.sh"
open "$ROOT/dist/APFSFind.app" --args "$@"
