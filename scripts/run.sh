#!/bin/bash
# Builds and launches FanGlass.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$DIR/scripts/build.sh" && open "$DIR/build/FanGlass.app"
