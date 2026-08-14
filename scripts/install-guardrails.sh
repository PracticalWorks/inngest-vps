#!/usr/bin/env bash
set -euo pipefail
# Durable installation: never use npx, whose evictable cache can silently disable hooks.
npm install --global "@practicalworks/guardrails@0.1.1"
factory-guardrails install
factory-guardrails status
