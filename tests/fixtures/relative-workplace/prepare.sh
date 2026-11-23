#!/usr/bin/env bash
set -euo pipefail
if (( $# != 2 )); then
  printf '%s\n' 'usage: prepare.sh absolute|relative ABSOLUTE_NEW_DIRECTORY' >&2
  exit 2
fi
case $1 in
  absolute|relative) edition=$1 ;;
  *) printf '%s\n' "unknown path edition: $1" >&2; exit 2 ;;
esac
fixture=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo=$(cd -P -- "$fixture/../../.." && pwd -P)
destination=$2
if [[ $destination != /* || -e $destination || -L $destination ]]; then
  printf '%s\n' "destination must be a new absolute path: $destination" >&2
  exit 2
fi
mkdir -- "$destination"
cp -R -- "$fixture/../reader-workplace/programs" "$destination/"
cp -- "$fixture/workplace.json" "$fixture/../reader-workplace/tmux.conf" "$destination/"
mkdir -- "$destination/layers"
for layer in Structure Access Agents Host; do
  cp -- "$repo/layers/$layer.typify" "$destination/layers/$layer.typify"
done
if [[ $edition == relative ]]; then
  cp -R -- "$fixture/programs/." "$destination/programs/"
fi
