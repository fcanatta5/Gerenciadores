# toolchain env - source this file
# Usage:
#   . /usr/local/share/toolchain/env.sh
#
# You may override defaults before sourcing:
#   TARGET=... TC_PREFIX=... TC_SYSROOT=... . /usr/local/share/toolchain/env.sh

# Defaults expected from pm-bootstrap.sh layout:
: "${TARGET:=x86_64-linux-musl}"
: "${TC_PREFIX:=/state/toolchain/prefix}"
: "${TC_SYSROOT:=/state/toolchain/sysroot}"

# Toolchain in PATH
export TARGET TC_PREFIX TC_SYSROOT
export PATH="${TC_PREFIX}/bin:${PATH}"

# Prefer prefixed cross tools if present
if [ -x "${TC_PREFIX}/bin/${TARGET}-gcc" ]; then
  export CC="${TC_PREFIX}/bin/${TARGET}-gcc"
  export CXX="${TC_PREFIX}/bin/${TARGET}-g++"
  export AR="${TC_PREFIX}/bin/${TARGET}-ar"
  export AS="${TC_PREFIX}/bin/${TARGET}-as"
  export LD="${TC_PREFIX}/bin/${TARGET}-ld"
  export RANLIB="${TC_PREFIX}/bin/${TARGET}-ranlib"
  export STRIP="${TC_PREFIX}/bin/${TARGET}-strip"
else
  # fallback: host compiler (not ideal for the intended workflow)
  : "${CC:=cc}"
  : "${CXX:=c++}"
  export CC CXX
fi

# Default sysroot flags
# Keep existing flags and append sysroot.
export CFLAGS="${CFLAGS:-} --sysroot=${TC_SYSROOT}"
export CPPFLAGS="${CPPFLAGS:-} --sysroot=${TC_SYSROOT}"
export LDFLAGS="${LDFLAGS:-} --sysroot=${TC_SYSROOT}"
