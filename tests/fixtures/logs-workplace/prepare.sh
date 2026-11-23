#!/usr/bin/env bash
set -euo pipefail
if (( $# != 1 )); then
  printf '%s\n' 'usage: prepare.sh ABSOLUTE_NEW_CONFIG_DIRECTORY' >&2
  exit 2
fi
fixture=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo=$(cd -P -- "$fixture/../../.." && pwd -P)
destination=$1
bash "$fixture/../comms-workplace/prepare.sh" "$destination"
cp -- "$fixture/workplace.json" "$destination/workplace.json"
cp -- "$repo/layers/Logs.typify" "$destination/layers/Logs.typify"
cp -R -- "$fixture/programs/." "$destination/programs/"
for address in '' 'OFFICE[harbor]' 'OFFICE[harbor]/ROOM[dock]' 'OFFICE[harbor]/ROOM[dock]/SEAT[pilot]' 'OFFICE[orchard]/ROOM[barn]/SEAT[grower]'; do
  addition="$fixture/record-reach/${address:+$address/}COMMS.typify"
  target="$destination/programs/${address:+$address/}COMMS.typify"
  mkdir -p -- "${target%/*}"
  cat -- "$addition" >> "$target"
done
