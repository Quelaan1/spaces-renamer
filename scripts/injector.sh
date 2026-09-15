#!/bin/sh
#
# injector.sh — loads and unloads spaces-renamer.dylib into the process that draws the Mission
# Control Spaces bar (WindowManager on macOS 27+, Dock on macOS 26). It is the single mechanism
# behind both the app's activation UI and manual Terminal use, and supports two injectors:
#
#   dyld   DYLD_INSERT_LIBRARIES via a per-user LaunchAgent. No root. Reversible with `launchctl
#          unsetenv` and a host restart. The dylib is loaded into every GUI process launched
#          afterwards, but its constructor no-ops unless the host is WindowManager/Dock.
#
#   mip    A MIP bundle dropped into MIP's system Bundles directory. Requires root and a working
#          MIP install (https://github.com/LIJI32/MIP); MIP loads it only into the executables
#          named in the bundle's Info.plist. Survives reboot with no login agent.
#
# Usage:
#   injector.sh status
#   injector.sh host
#   injector.sh dyld on   <dylib>
#   injector.sh dyld off
#   injector.sh dyld boot                 # internal: invoked by the LaunchAgent at login
#   injector.sh mip  on   <assembled .bundle>   # needs root
#   injector.sh mip  off                        # needs root
#
# Prerequisites for either injector: SIP disabled and `boot-args=-arm64e_preview_abi` (see README).

set -eu

SUPPORT="$HOME/Library/Application Support/SpacesRenamer"
DYLIB_STORE="$SUPPORT/spaces-renamer.dylib"
SCRIPT_STORE="$SUPPORT/injector.sh"

AGENT_LABEL="com.alexbeals.SpacesRenamer.injector"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

MIP_ROOT="/Library/Apple/System/Library/Frameworks/mip"
MIP_BUNDLES="$MIP_ROOT/Bundles"
MIP_BUNDLE_NAME="SpacesRenamer.mip.bundle"

DYLD_VAR="DYLD_INSERT_LIBRARIES"

log() { printf 'injector: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

# The process that renders the Spaces bar for this macOS release.
host_process() {
  major=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$major" -ge 27 ] 2>/dev/null; then echo WindowManager; else echo Dock; fi
}

restart_host() {
  host=$(host_process)
  /usr/bin/killall "$host" 2>/dev/null || true
  log "restarted $host"
}

# ---------------------------------------------------------------------------- dyld

write_agent_plist() {
  /bin/mkdir -p "$(dirname "$AGENT_PLIST")"
  cat >"$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$SCRIPT_STORE</string>
		<string>dyld</string>
		<string>boot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$SUPPORT/injector.log</string>
</dict>
</plist>
PLIST
}

dyld_on() {
  dylib=${1:-}
  [ -n "$dylib" ] || die "dyld on: missing <dylib> path"
  [ -f "$dylib" ] || die "dyld on: no dylib at $dylib"
  dylib=$(cd "$(dirname "$dylib")" && printf '%s/%s' "$(pwd)" "$(basename "$dylib")")

  /bin/mkdir -p "$SUPPORT"
  /bin/cp "$dylib" "$DYLIB_STORE"
  # Keep a stable copy of this script for the LaunchAgent, so activation survives moving the app.
  if [ "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" != "$SCRIPT_STORE" ]; then
    /bin/cp "$0" "$SCRIPT_STORE"
  fi

  write_agent_plist
  # (Re)load the agent for this login session; RunAtLoad runs `dyld boot`, which sets the
  # environment variable and restarts the host so it inherits the library.
  uid=$(id -u)
  launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$AGENT_PLIST"
  log "dyld injector activated ($DYLIB_STORE)"
}

# Invoked by the LaunchAgent (and once at activation): publish the variable and restart the host.
dyld_boot() {
  [ -f "$DYLIB_STORE" ] || die "dyld boot: dylib missing ($DYLIB_STORE); run 'dyld on <dylib>' first"
  launchctl setenv "$DYLD_VAR" "$DYLIB_STORE"
  restart_host
}

dyld_off() {
  uid=$(id -u)
  launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
  /bin/rm -f "$AGENT_PLIST"
  launchctl unsetenv "$DYLD_VAR"
  restart_host
  /bin/rm -f "$DYLIB_STORE" "$SCRIPT_STORE"
  log "dyld injector removed"
}

# ---------------------------------------------------------------------------- mip

require_root() { [ "$(id -u)" -eq 0 ] || die "$1 requires root (run under sudo or the app's admin prompt)"; }

mip_on() {
  bundle=${1:-}
  require_root "mip on"
  [ -d "$MIP_ROOT" ] || die "MIP is not installed at $MIP_ROOT (see README: install LIJI32/MIP first)"
  [ -n "$bundle" ] || die "mip on: missing assembled <.bundle> path"
  [ -d "$bundle" ] || die "mip on: no bundle directory at $bundle"
  /bin/mkdir -p "$MIP_BUNDLES"
  dest="$MIP_BUNDLES/$MIP_BUNDLE_NAME"
  /bin/rm -rf "$dest"
  /bin/cp -R "$bundle" "$dest"
  # Apple-signed hosts refuse to load libraries not owned by root.
  /usr/sbin/chown -R root:wheel "$dest"
  restart_host
  log "mip bundle installed to $dest"
}

mip_off() {
  require_root "mip off"
  /bin/rm -rf "$MIP_BUNDLES/$MIP_BUNDLE_NAME"
  restart_host
  log "mip bundle removed"
}

# ---------------------------------------------------------------------------- status

status() {
  echo "host=$(host_process)"

  env_val=$(launchctl getenv "$DYLD_VAR" 2>/dev/null || true)
  if [ -f "$AGENT_PLIST" ]; then echo "dyld_agent=present"; else echo "dyld_agent=absent"; fi
  if [ -n "$env_val" ]; then echo "dyld_env=set"; else echo "dyld_env=unset"; fi
  if [ -f "$AGENT_PLIST" ] && [ -n "$env_val" ]; then dyld=on; else dyld=off; fi
  echo "dyld=$dyld"

  if [ -d "$MIP_ROOT" ]; then echo "mip_installed=yes"; else echo "mip_installed=no"; fi
  if [ -d "$MIP_BUNDLES/$MIP_BUNDLE_NAME" ]; then mipb=on; else mipb=off; fi
  echo "mip_bundle=$mipb"

  if [ "$mipb" = on ]; then active=mip
  elif [ "$dyld" = on ]; then active=dyld
  else active=none; fi
  echo "active=$active"
}

# ---------------------------------------------------------------------------- dispatch

cmd=${1:-status}
case "$cmd" in
  status) status ;;
  host)   host_process ;;
  dyld)
    sub=${2:-}
    case "$sub" in
      on)   dyld_on "${3:-}" ;;
      off)  dyld_off ;;
      boot) dyld_boot ;;
      *)    die "usage: injector.sh dyld on <dylib> | off" ;;
    esac ;;
  mip)
    sub=${2:-}
    case "$sub" in
      on)  mip_on "${3:-}" ;;
      off) mip_off ;;
      *)   die "usage: injector.sh mip on <.bundle> | off  (root)" ;;
    esac ;;
  *) die "usage: injector.sh {status|host|dyld|mip} ..." ;;
esac
