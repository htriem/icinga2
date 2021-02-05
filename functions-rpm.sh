#!/bin/bash

# shellcheck source=functions-common.sh
. "$(dirname "$(readlink -f "$0")")"/functions-common.sh

detect_project() {
  IFS=" " read -r -a specs <<< "$(ls ./*.spec)"

  if [ "${#specs[@]}" -eq 0 ]; then
    echo "No Spec file found!" >&2
    exit 1
  elif [ "${#specs[@]}" -gt 1 ]; then
    echo "More than one spec file found!" >&2
    exit 1
  else
    basename "${specs[0]}" .spec
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    os=$(awk -F"=" '/^ID=/ {print $2}' /etc/os-release | sed -e 's/^"//' -e 's/"$//')

    if [ -n "$os" ]; then
      echo "$os"
      return
    else
      echo "Could not detect os (ID) from /etc/os-release" >&2
      exit 1
    fi
  elif [ -f /etc/redhat-release ]; then
    # before el7
    os=$(awk '{ print tolower($1) }' /etc/redhat-release)

    if [ -n "$os" ]; then
      echo "$os"
      return
    else
      echo "Could not detect os from /etc/redhat-release" >&2
      exit 1
    fi
  else
    echo "Could not detect os, looking in /etc/os-release /etc/redhat-release" >&2
    exit 1
  fi
}

detect_dist() {
  # TODO: verify for SUSE
  if [ -f /etc/os-release ]; then
    dist=$(awk -F= '/^VERSION_ID=/ {print $2}' /etc/os-release | sed -e 's/^"//' -e 's/"$//')

    if [ -n "$dist" ]; then
      echo "$dist"
      return
    else
      echo "Could not detect dist (VERSION_ID) from /etc/os-release" >&2
      exit 1
    fi
  elif [ -f /etc/redhat-release ]; then
    # before el7
    dist=$(grep -Po '(?<=\s)(\d+(\.\d+)+)(?=\s)' /etc/redhat-release | cut -d. -f1)

    if [ -n "$dist" ]; then
      echo "$dist"
      return
    else
      echo "Could not detect dist version from /etc/redhat-release" >&2
      exit 1
    fi
  else
    echo "Could not detect dist, looking in /etc/os-release /etc/redhat-release" >&2
    exit 1
  fi
}

detect_arch() {
  # TODO: verify for SUSE
  IFS=" " read -r -a arches <<< "$(rpm -qa rpm "*-release" --qf "%{arch}\\n"  | sort -u | grep -v noarch)"

  if [ "${#arches[@]}" -eq 0 ]; then
    echo "No basearch found while looking for *-release or rpm packages!" >&2
    exit 1
  elif [ "${#arches[@]}" -gt 1 ]; then
    echo "More than one base arch found with *-release or rpm packages!" >&2
    exit 1
  else
    echo "${arches[0]}"
  fi
}

require_var() {
  err=0
  for var in "$@"; do
    if [ -z "${!var}" ]; then
      echo "Variable $var is not set!" >&2
      err+=1
    fi
  done
  [ "$err" -eq 0 ] || exit 1
  echo
}

get_rpmbuild() {
    local RPMBUILD dist

    dist="$(rpm -E '%{?dist}' | sed 's/\(\.centos\)\?$/.'"$ICINGA_BUILD_BRANDING_TAG"'/')"
    # TODO: target_arch needed?
    #local setarch=''
    #if [ -n "$target_arch" ]; then
    #  setarch="setarch ${target_arch}"
    #fi
    #  ${setarch} \
    RPMBUILD=(
        /usr/bin/rpmbuild \
        --define "vendor $ICINGA_BUILD_BRANDING_VENDOR" \
        --define "dist $dist" \
        --define "_topdir ${WORKDIR}/build" \
        "$@"
    )

    if [ -f /etc/os-release ]; then
      source /etc/os-release
    fi
    if [ "$ID" != sles ] && [[ "$VERSION" != 11.* ]]; then
      RPMBUILD+=(
        --define "_buildrootdir %{_topdir}/BUILDROOT" \
        --define "buildroot %{_buildrootdir}/%{name}" \
      )
    fi

    declare -p RPMBUILD
}

rpmbuild() {
    local RPMBUILD
    eval "$(get_rpmbuild "$@")"
    "${RPMBUILD[@]}"
}

find_compilers() {
  local location=${1:-/usr/bin}
  cd "$location" || return 1
  ls {cc,cpp,[gc]++,gcc}{,-*} 2>/dev/null || true
}

patch_scl_ccache() {
  local name="$1"
  local cache_path="$2"

  echo "Ensuring SCL ${name} supports ccache..."

  # This is the only good way to re-add ccache to top of PATH
  # scl enable (inside icinga2.spec) will set its own path first
  local enable_file="/opt/rh/${name}/enable"
  local line="PATH=\"${cache_path}:\${PATH}\""
  if ! grep -qF "${line}" "${enable_file}"; then
    echo "Adding '${line}' to ${enable_file}"
    sudo sh -ec "echo '${line}' >>'${enable_file}'"
  fi
}

# repair/prepare ccache (needed on some distros like CentOS 5 + 6, SUSE, OpenSUSE)
preconfigure_ccache() {
  CCACHE_LINKS="$(rpm -E %_libdir)"/ccache
  IFS=" " read -r -a compilers <<< "$(find_compilers)"

  devtoolsets=''
  if [ -d /opt/rh ]; then
    if devtoolsets="$(cd /opt/rh && ls -d devtoolset-*)"; then
      for devtoolset in $devtoolsets; do
        patch_scl_ccache "$devtoolset" "${CCACHE_LINKS}"

        IFS=" " read -r -a extra_compilers <<< "$(find_compilers "/opt/rh/${devtoolset}/root/usr/bin")"
        compilers+=("${extra_compilers[@]}")
      done
    fi
  fi

  echo 'Preparing/Repairing ccache symlinks...'
  (
    set -e
    test -d "${CCACHE_LINKS}" || sudo mkdir "${CCACHE_LINKS}"
    cd "${CCACHE_LINKS}"

    for comp in "${compilers[@]}"; do
      [ ! -e "${comp}" ] || continue
      sudo ln -svf /usr/bin/ccache "${comp}"
    done
  )

  # Enable ccache as a default wrapper for compilers
  PATH="${CCACHE_LINKS}:${PATH}"
}

setup_extra_repository() {
  local extra_name=icinga-build-extra
  local extra_repository="${ICINGA_BUILD_EXTRA_REPOSITORY}"

  echo "[ Update extra repository ]"

  if [ -n "${ICINGA_BUILD_EXTRA_REPOSITORY_BASE}" ]; then
    extra_repository="${ICINGA_BUILD_EXTRA_REPOSITORY_BASE}/${extra_repository}"
  fi # base

  case "$ICINGA_BUILD_OS" in
    opensuse*|sles)
      if [ -n "${ICINGA_BUILD_EXTRA_REPOSITORY_USERNAME}" ]; then
        echo "Creating /etc/zypp/credentials.d/${extra_name}"
        extra_repository="${extra_repository}?credentials=${extra_name}"
        (
          echo "username=${ICINGA_BUILD_EXTRA_REPOSITORY_USERNAME}"
          echo "password=${ICINGA_BUILD_EXTRA_REPOSITORY_PASSWORD}"
        ) | sudo bash -c "cat >'/etc/zypp/credentials.d/${extra_name}'"
      fi
      (
        if [ -f /etc/os-release ]; then
          source /etc/os-release
        fi
        opt=()
        if [ "$ID" != sles ] && [[ "$VERSION" != 11.* ]]; then
          opt+=(--priority 50)
        fi
        set -ex
        sudo zypper --non-interactive removerepo "${extra_name}" || true
        sudo zypper --non-interactive addrepo "${opt[@]}" --refresh "${extra_repository}" "${extra_name}"
      ) || exit 1
      ;;
    *)
      # TODO: implement
      echo "Other OS than SUSE are not yet implemented!" >&2
      #exit 1
      ;;
  esac # ICINGA_BUILD_OS
}

prepare_system_config() {
  if [ -n "${ICINGA_BUILD_EXTRA_REPOSITORY}" ]; then
    setup_extra_repository
  fi
}

: "${ICINGA_BUILD_PROJECT:="$(detect_project)"}"
: "${ICINGA_BUILD_OS:="$(detect_os)"}"
: "${ICINGA_BUILD_DIST:="$(detect_dist)"}"
: "${ICINGA_BUILD_ARCH:="$(detect_arch)"}"
: "${ICINGA_BUILD_TYPE:="release"}"
: "${ICINGA_BUILD_UPSTREAM_BRANCH:="master"}"
: "${ICINGA_BUILD_IGNORE_LINT:=1}"
: "${ICINGA_BUILD_BRANDING_TAG:=icinga}"
: "${ICINGA_BUILD_BRANDING_VENDOR:=Icinga.com}"

[ -n "${ICINGA_NO_ENV}" ] || print_build_env

require_var ICINGA_BUILD_PROJECT ICINGA_BUILD_OS ICINGA_BUILD_DIST ICINGA_BUILD_ARCH ICINGA_BUILD_TYPE
prepare_system_config
export_build_env

export LANG=C
WORKDIR="$(pwd)"
BUILDDIR='build'
export WORKDIR BUILDDIR

# vi: ts=2 sw=2 expandtab
