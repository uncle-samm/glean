#!/bin/sh
set -e

echo "=== Release ==="

gleam format --check src test
gleam test

sh scripts/push.sh
sh scripts/tag.sh
/usr/bin/expect scripts/publish.sh

echo "=== Release complete ==="
