#!/usr/bin/env bash
set -euo pipefail
if (( $# != 1 )); then
  printf '%s\n' 'usage: prepare.sh ABSOLUTE_NEW_CONFIG_DIRECTORY' >&2
  exit 2
fi
fixture=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo=$(cd -P -- "$fixture/../../.." && pwd -P)
destination=$1
bash "$fixture/../home-runtime-workplace/prepare.sh" "$destination"
cp -- "$fixture/workplace.json" "$destination/workplace.json"
cp -- "$repo/layers/Comms.typify" "$destination/layers/"
cp -R -- "$fixture/programs/." "$destination/programs/"
