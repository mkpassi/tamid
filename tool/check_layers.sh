#!/usr/bin/env bash
set -e
if grep -rn --include="*.dart" -E "import .*(package:flutter/|package:drift|package:riverpod|dart:io)" lib/domain/ 2>/dev/null; then
  echo "❌ lib/domain must be pure Dart — framework import found above."
  exit 1
fi
echo "✅ domain layer clean"
