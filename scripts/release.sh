#!/bin/sh
set -e

echo "=== Release ==="

sh scripts/push.sh
sh scripts/tag.sh
/usr/bin/expect scripts/publish.sh

echo "=== Release complete ==="
