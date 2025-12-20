# Auto-load toolchain env if present and if user wants it.
# Enable by setting: export USE_TOOLCHAIN=1

if [ "${USE_TOOLCHAIN:-0}" = "1" ] && [ -f /usr/local/share/toolchain/env.sh ]; then
  . /usr/local/share/toolchain/env.sh
fi
