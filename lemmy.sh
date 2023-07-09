#!/usr/bin/env bash
set -Eeuo pipefail

lemmy-help -f lua/jdtls.lua lua/jdtls/dap.lua lua/jdtls/tests.lua >doc/jdtls.txt
