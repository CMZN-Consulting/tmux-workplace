#!/usr/bin/env bash
set -euo pipefail
if (( $# != 1 )); then
  printf '%s\n' 'usage: prepare.sh ABSOLUTE_NEW_CONFIG_DIRECTORY' >&2
  exit 2
fi
fixture=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo=$(cd -P -- "$fixture/../../.." && pwd -P)
destination=$1
bash "$fixture/../logs-workplace/prepare.sh" "$destination"
cp -- "$fixture/workplace.json" "$destination/workplace.json"
# The inherited source uses the historical base layers. W4 uses the current ones.
for layer in Structure Access Agents Host Identity SSH; do
  cp -- "$repo/layers/$layer.typify" "$destination/layers/"
done
cp -R -- "$fixture/programs/." "$destination/programs/"
