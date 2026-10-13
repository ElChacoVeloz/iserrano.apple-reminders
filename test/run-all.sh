#!/usr/bin/env bash
# All the widget's tests: the helper (python) and the bar model (node).
# No dependencies.
set -u

cd "$(dirname "$0")/.."

status=0

echo "=== helper (python unittest)"
python3 test/test_color.py || status=1

echo
echo "=== Model.js (node)"
if command -v node >/dev/null 2>&1; then
  node test/model.test.js || status=1
else
  echo "  (no node: skipped)"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "FAILURES"
fi
exit "$status"
