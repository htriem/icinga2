#!/bin/bash

export_build_env() {
  for var in $( (set -o posix; set) | grep -E ^ICINGA | cut -d= -f1)
  do
    # shellcheck disable=SC2163
    export "${var}"
  done
}

print_build_env() {
  echo "[ Icinga Build Environment ]"
  (set -o posix; set) | grep -E ^ICINGA | sed -r '/(TOKEN|PASSWORD|AUTH)/ { s/=.*$/=xxx/ }'
}
