#!/bin/sh
set -e

branch=$(git branch --show-current)
if [ "$branch" != "main" ]; then
  echo "Not on main branch (on $branch). Switch to main first."
  exit 1
fi

echo "Pushing main to origin..."
git push origin main

echo "Done."
