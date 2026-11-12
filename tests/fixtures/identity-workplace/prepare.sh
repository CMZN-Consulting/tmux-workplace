#!/usr/bin/env bash
set -euo pipefail
if (( $# != 2 )); then
  printf '%s\n' 'usage: prepare.sh workplace-held|workplace-none|absent ABSOLUTE_NEW_DIRECTORY' >&2
  exit 2
fi
case $1 in
  workplace-held|workplace-none|absent) selected=$1 ;;
  *) printf '%s\n' "unknown identity fixture: $1" >&2; exit 2 ;;
esac
fixture=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo=$(cd -P -- "$fixture/../../.." && pwd -P)
destination=$2
if [[ $destination != /* || -e $destination || -L $destination ]]; then
  printf '%s\n' "destination must be a new absolute path: $destination" >&2
  exit 2
fi
mkdir -- "$destination"
cp -R -- "$fixture/../reader-workplace/layers" "$fixture/../reader-workplace/programs" "$destination/"
cp -- "$fixture/workplace.json" "$fixture/../reader-workplace/tmux.conf" "$destination/"
cp -- "$repo/layers/Identity.typify" "$destination/layers/Identity.typify"
if [[ $selected != absent ]]; then
  cp -R -- "$fixture/$selected/programs/." "$destination/programs/"
fi
