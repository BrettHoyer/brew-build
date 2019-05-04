#!/usr/bin/env bash

# Copyright (c) YugaByte, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.  See the License for the specific language governing permissions and limitations
# under the License.
#

set -euo pipefail

COMMON_SH="${0%/*}/linuxbrew-common.sh"
. "$COMMON_SH"

export HOMEBREW_NO_AUTO_UPDATE=1

[[ -x ./bin/brew ]] || (echo "This script should be run inside Linuxbrew directory."; exit 1)

YB_USE_SSE4=${YB_USE_SSE4:-1}

echo
echo "============================================================================================"
echo "Building Linuxbrew in $PWD"
echo "YB_USE_SSE4=$YB_USE_SSE4"
echo "============================================================================================"
echo

cd "$(realpath .)"
BREW_HOME=$PWD

LEN=${#BREW_HOME}
[[ $LEN -eq $ABS_PATH_LIMIT ]] || (echo "Linuxbrew absolute path should be exactly $ABS_PATH_LIMIT \
 bytes, but actual length is $LEN bytes: $BREW_HOME"; exit 1)

# -------------------------------------------------------------------------------------------------
# Setting compiler flags
# -------------------------------------------------------------------------------------------------

sse4_flags=""
if [[ $YB_USE_SSE4 == "0" ]]; then
  echo "YB_USE_SSE4=$YB_USE_SSE4, disabling use of SSE4"
  sse4_flags="-mno-sse4.1 -mno-sse4.2"
  export HOMEBREW_ARCH="core2"
else
  echo "YB_USE_SSE4=$YB_USE_SSE4, enabling use of SSE4"
  export HOMEBREW_ARCH="ivybridge"
fi

# TODO: figure out why we can't put -march=$HOMEBREW_ARCH in the flags.
extra_flags="$sse4_flags -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma"

# These flags might not be understood by the OS-installed compiler but the Linuxbrew-installed
# compiler should understand them.
additional_extra_flags="-no-abm -no-movbe"

echo "Extra compiler flags: $extra_flags"

cat <<EOF | patch -p1
diff --git a/Library/Homebrew/extend/ENV/super.rb b/Library/Homebrew/extend/ENV/super.rb
index 2aa440689..c7d31daa1 100644
--- a/Library/Homebrew/extend/ENV/super.rb
+++ b/Library/Homebrew/extend/ENV/super.rb
@@ -54,7 +54,7 @@ module Superenv
     self["HOMEBREW_OPT"] = "#{HOMEBREW_PREFIX}/opt"
     self["HOMEBREW_TEMP"] = HOMEBREW_TEMP.to_s
     self["HOMEBREW_OPTFLAGS"] = determine_optflags
-    self["HOMEBREW_ARCHFLAGS"] = ""
+    self["HOMEBREW_ARCHFLAGS"] = "$extra_flags"
     self["CMAKE_PREFIX_PATH"] = determine_cmake_prefix_path
     self["CMAKE_FRAMEWORK_PATH"] = determine_cmake_frameworks_path
     self["CMAKE_INCLUDE_PATH"] = determine_cmake_include_path
EOF

# -------------------------------------------------------------------------------------------------
# OpenSSL flags patching
# -------------------------------------------------------------------------------------------------

openssl_formula=./Library/Taps/homebrew/homebrew-core/Formula/openssl.rb
openssl_orig=./Library/Taps/homebrew/homebrew-core/Formula/openssl.rb.orig

if [[ ! -e "$openssl_orig" ]]; then
  # Run brew info, so that brew downloads the openssl formula which we want to patch.
  ./bin/brew info openssl >/dev/null
  cp "$openssl_formula" "$openssl_orig"
fi

cp "$openssl_orig" "$openssl_formula"
cat <<EOF | patch "$openssl_formula"
@@ -61,6 +61,7 @@ class Openssl < Formula
       end
       args << "enable-md2"
     end
+    args += %w[-march=$HOMEBREW_ARCH $extra_flags $additional_extra_flags]
     system "perl", "./Configure", *args
     system "make", "depend"
     system "make"
EOF
unset sse4_args

readonly LINUXBREW_PACKAGES=(
  autoconf
  automake
  bzip2
  flex
  gcc
  icu4c
  libtool
  libuuid
  ninja
  openssl
  readline
  s3cmd
)

# Temporarily excluded packages.
readonly LINUXBREW_PACKAGES_DISABLED=(
  maven
)

successful_packages=()
failed_packages=()

for package in "${LINUXBREW_PACKAGES[@]}"; do

  if ( set -x; ./bin/brew install --build-from-source "$package" ); then
    successful_packages+=( "$package" )
  else
    echo >&2 "Failed to install package: $package"
    failed_packages+=( "$package" )
  fi
done

if [[ ${#successful_packages[@]} -gt 0 ]]; then
  echo "Successfully installed packages: ${successful_packages[*]}"
fi

if [[ ${#failed_packages[@]} -gt 0 ]]; then
  echo >&2 "Failed to install packages: ${failed_packages[*]}"
  exit 1
fi

if [[ ! -e VERSION_INFO ]]; then
  commit_id=$(git rev-parse HEAD)
  echo "Linuxbrew commit ID: $commit_id" >VERSION_INFO.tmp
  pushd Library/Taps/homebrew/homebrew-core
  commit_id=$(git rev-parse HEAD)
  popd
  echo "homebrew-core commit ID: $commit_id" >>VERSION_INFO.tmp
  mv VERSION_INFO.tmp VERSION_INFO
fi

echo "Updating symlinks ..."
find . -type l | while read f
do
  target=$(readlink "$f")
  if [[ -e $f ]]; then
    real_target=$(realpath "$f")
    if [[ $real_target != $BREW_HOME* && $real_target != $target ]]; then
      # We want to convert relative links pointing outside of Linuxbrew to absolute links.
      # -f to allow relinking. -T to avoid linking inside directory if $f already exists as
      # directory.
      ln -sfT "$real_target" "$f"
    fi
  else
    echo >&2 "Link $f seems broken"
  fi
done

echo "Preparing list of files to be patched during installation ..."
find ./Cellar -type f | while read f
do
  if grep -q "$BREW_HOME" "$f"; then
    echo "$f"
  fi
done | sort >FILES_TO_PATCH

find . -type l | while read f
do
  if [[ -e "$f" && $(readlink "$f") == $BREW_HOME* ]]; then
    echo "$f"
  fi
done | sort >LINKS_TO_PATCH

BREW_HOME_ESCAPED=$(get_escaped_sed_replacement_str "$BREW_HOME")

cp $COMMON_SH .
sed "s/{{ orig_brew_home }}/$BREW_HOME_ESCAPED/g" "${0%/*}/post_install.template" >post_install.sh
chmod +x post_install.sh

brew_home_dir=${BREW_HOME##*/}
distr_name=${brew_home_dir%-*}
archive_name=$distr_name.tar.gz
distr_path=$(realpath "../$archive_name")
echo "Preparing Linuxbrew distribution archive: $distr_path ..."
distr_name_escaped=$(get_escaped_sed_replacement_str "$distr_name" "%")
tar zcf "$distr_path" . --transform s%^./%$distr_name_escaped/% --exclude ".git"
pushd ..
sha256sum $archive_name >$archive_name.sha256
popd
echo "Done"
