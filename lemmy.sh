#!/usr/bin/env bash
set -Eeuo pipefail

lemmy-help lua/jdtls.lua lua/jdtls/dap.lua >doc/jdtls.txt
