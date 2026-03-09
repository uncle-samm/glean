#!/bin/sh
set -e

version=$(grep '^version' gleam.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
tag="v${version}"

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists."
  exit 1
fi

echo "Creating tag $tag..."
git tag "$tag"

echo "Pushing tag $tag..."
git push origin "$tag"

echo "Done."
