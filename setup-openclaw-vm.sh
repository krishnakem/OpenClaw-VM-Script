#!/usr/bin/env bash
#
# setup-agent-vm.sh — Provision a blank, reusable OpenClaw "agent VM" template.
#
# Turns a fresh GCP project into "the OpenClaw box": a Debian 12 VM with an
# XFCE desktop reachable through the browser (Chrome Remote Desktop), Node 22+,
# Google Chrome, OpenClaw installed (NOT onboarded), and VM plugin installer
# shell scripts downloaded. No specific agent (Kowalski, etc.) is installed —
# plugins are a separate per-agent step and are explicitly OUT OF SCOPE here.
#
# Architecture note: this script runs on the OPERATOR'S LAPTOP. Phase 1 creates
# the VM with gcloud; phases 2-5 run on the VM over `gcloud compute ssh`. We do
# NOT install from inside the CRD desktop, because OS Login passwordless sudo is
# reliable over gcloud SSH but may prompt for an absent password inside CRD.
#
# Usage:
#   ./setup-agent-vm.sh [--name NAME] [--zone ZONE] [--machine-type TYPE]
#                       [--project PROJECT_ID]
#
# Defaults: name=experiment-claw  zone=us-west1-a  machine-type=e2-standard-2
#
# One point requires a human:
#   * CRD enrollment: you paste a `start-host --code="..."` command from
#     remotedesktop.google.com/headless (Google won't mint that code for a script).
#
# OpenClaw is INSTALLED but NOT onboarded — you run `openclaw onboard
# --install-daemon` yourself afterward (see the checklist printed at the end).
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults / tunables
# --------------------------------------------------------------------------- #
VM_NAME="experiment-claw"
ZONE="us-west1-a"             # us-west (Oregon). Override with --zone for another.
MACHINE_TYPE="e2-standard-2"   # 2 vCPU / 8 GB. e2-medium (4 GB) crashes Chromium.
PROJECT=""                     # empty -> use the active gcloud config project

IMAGE_FAMILY="debian-12"       # bookworm; amd64. (debian-12-arm64 is the ARM one — not this.)
IMAGE_PROJECT="debian-cloud"
BOOT_DISK_SIZE="30GB"          # 10 GB default fills up (Chromium + node_modules + apt + DE).
BOOT_DISK_TYPE="pd-balanced"

# OpenClaw is installed only — onboarding (`openclaw onboard --install-daemon`)
# is left to the operator and is intentionally NOT run by this script.

NODE_MAJOR="22"               # OpenClaw needs >= 22.14. Node 20 will not work.
PLUGIN_INSTALLER_REPO="https://github.com/krishnakem/VM-Plugin-Installer-Script.git"

# Shared system libraries that any Chromium-based browser dynamically links
# against to launch. These are generic Chromium runtime deps (NOT Playwright).
# Google Chrome (phase 3) pulls in most of them anyway; installing the full set
# here keeps any future browser-driving agent from failing on a missing .so.
# DEBIAN 12 names — do not port the Ubuntu 24.04 *t64 names here, they don't
# exist on bookworm.
CHROMIUM_LIBS=(
  libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2
  libxkbcommon0 libatspi2.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2
  libgbm1 libpango-1.0-0 libcairo2 libasound2
)

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^#\s\?//'
  exit "${1:-0}"
}

# --------------------------------------------------------------------------- #
# Arg parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         VM_NAME="${2:?--name needs a value}"; shift 2 ;;
    --zone)         ZONE="${2:?--zone needs a value}"; shift 2 ;;
    --machine-type) MACHINE_TYPE="${2:?--machine-type needs a value}"; shift 2 ;;
    --project)      PROJECT="${2:?--project needs a value}"; shift 2 ;;
    -h|--help)      usage 0 ;;
    *)              die "Unknown argument: $1 (try --help)" ;;
  esac
done

# Common gcloud flags shared by create / ssh / scp.
GCLOUD_COMMON=( "--zone=${ZONE}" )
[[ -n "$PROJECT" ]] && GCLOUD_COMMON+=( "--project=${PROJECT}" )

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
command -v gcloud >/dev/null 2>&1 || die "gcloud not found. Install the Google Cloud SDK and run 'gcloud auth login'."

# ARM is a dead end: Chrome Remote Desktop ships no ARM .deb. Reject T2A / Axion(C4A).
case "$MACHINE_TYPE" in
  t2a-*|c4a-*|*-arm|*arm64*)
    die "ARM machine type '$MACHINE_TYPE' is unsupported: Chrome Remote Desktop has no ARM build. Use an x86_64 type (e.g. e2-standard-2)." ;;
esac

EFFECTIVE_PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$EFFECTIVE_PROJECT" && "$EFFECTIVE_PROJECT" != "(unset)" ]] \
  || die "No project set. Pass --project or run 'gcloud config set project <id>'."

log "Target"
info "Project      : $EFFECTIVE_PROJECT"
info "VM name      : $VM_NAME"
info "Zone         : $ZONE"
info "Machine type : $MACHINE_TYPE  (x86_64)"
info "Image        : $IMAGE_FAMILY / $IMAGE_PROJECT"
info "Boot disk    : $BOOT_DISK_SIZE ($BOOT_DISK_TYPE)"

# --------------------------------------------------------------------------- #
# Remote-exec helpers
# --------------------------------------------------------------------------- #

# Copy a local script to the VM home dir, run it, then delete the remote copy
# (preserving the script's exit code so set -e still aborts on failure).
remote_run_script() {
  local local_path="$1" remote_name="$2"
  gcloud compute scp "$local_path" "${VM_NAME}:${remote_name}" "${GCLOUD_COMMON[@]}" --quiet
  gcloud compute ssh "$VM_NAME" "${GCLOUD_COMMON[@]}" --quiet \
    --command="chmod +x ${remote_name} && bash ${remote_name}; rc=\$?; rm -f ${remote_name}; exit \$rc"
}

# Run a command on the VM with a TTY allocated (for interactive prompts).
remote_run_tty() {
  local cmd="$1"
  gcloud compute ssh "$VM_NAME" "${GCLOUD_COMMON[@]}" --quiet \
    --command="$cmd" -- -t
}

# =========================================================================== #
# PHASE 1 — Initialize the VM
# =========================================================================== #
log "Phase 1/5 — Creating the VM"

gcloud services enable compute.googleapis.com "${GCLOUD_COMMON[@]/--zone=$ZONE/}" \
  ${PROJECT:+--project="$PROJECT"} --quiet 2>/dev/null || true

if gcloud compute instances describe "$VM_NAME" "${GCLOUD_COMMON[@]}" >/dev/null 2>&1; then
  warn "Instance '$VM_NAME' already exists in $ZONE — reusing it (skipping create)."
else
  gcloud compute instances create "$VM_NAME" \
    "${GCLOUD_COMMON[@]}" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$BOOT_DISK_SIZE" \
    --boot-disk-type="$BOOT_DISK_TYPE"
fi

log "Waiting for SSH to come up (first connection also provisions keys)"
tries=0; max_tries=36   # ~6 min
until gcloud compute ssh "$VM_NAME" "${GCLOUD_COMMON[@]}" --quiet --command="true" >/dev/null 2>&1; do
  tries=$((tries + 1))
  [[ "$tries" -ge "$max_tries" ]] && die "SSH not reachable after ~6 min. If this is a locked-down VPC, you may need IAP: add --tunnel-through-iap to the gcloud ssh/scp calls and an IAP firewall rule."
  printf '    ...still waiting (%d/%d)\n' "$tries" "$max_tries"
  sleep 10
done
info "SSH is up."

# =========================================================================== #
# PHASE 2 — Desktop (XFCE) + Chrome Remote Desktop + Chromium runtime libs
# =========================================================================== #
log "Phase 2/5 — Installing XFCE desktop, Chrome Remote Desktop, and Chromium runtime libs"

PH2="$(mktemp)"; trap 'rm -f "${PH2:-}" "${PH3:-}" "${PH4:-}" "${PH5:-}" 2>/dev/null || true' EXIT
cat > "$PH2" <<PHASE2
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update

# The XFCE dependency chain can pull in keyboard-configuration, which prompts
# even in some noninteractive remote shells unless its values are preseeded.
printf '%s\n' \
  'keyboard-configuration keyboard-configuration/layoutcode string us' \
  'keyboard-configuration keyboard-configuration/modelcode string pc105' \
  'keyboard-configuration keyboard-configuration/variantcode string' \
  'keyboard-configuration keyboard-configuration/optionscode string' \
  | sudo debconf-set-selections
sudo apt-get install -y xfce4 xfce4-goodies xscreensaver desktop-base dbus-x11

# Chrome Remote Desktop apt source + signing key (--yes so re-runs can overwrite)
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/chrome-remote-desktop.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/chrome-remote-desktop.gpg] https://dl.google.com/linux/chrome-remote-desktop/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/chrome-remote-desktop.list >/dev/null
sudo apt-get update
sudo apt-get install -y chrome-remote-desktop

# Tell CRD to launch XFCE
echo "exec /etc/X11/Xsession /usr/bin/xfce4-session" \
  | sudo tee /etc/chrome-remote-desktop-session >/dev/null

# The SSH user must be in the chrome-remote-desktop group for CRD to run as it.
# Some CRD package versions don't create the group on install, so ensure it
# exists first (groupadd -f is a no-op if it already does). Picked up by the
# next, fresh SSH session — i.e. the start-host run.
sudo groupadd -f chrome-remote-desktop
sudo usermod -a -G chrome-remote-desktop "\$USER"

# Chromium runtime system libs (Debian 12 names)
sudo apt-get install -y ${CHROMIUM_LIBS[*]}

echo "Phase 2 OK."
PHASE2
remote_run_script "$PH2" "openclaw-phase2.sh"

# --------------------------------------------------------------------------- #
# Phase 2 pause — CRD OAuth enrollment (human required)
# --------------------------------------------------------------------------- #
cat <<'PROMPT'

    ----------------------------------------------------------------------
    CHROME REMOTE DESKTOP — ENROLLMENT (do this in your laptop browser)
    ----------------------------------------------------------------------
    Google will only mint the enrollment code in response to a human click,
    so this step can't be scripted.

      1. Open:  https://remotedesktop.google.com/headless
      2. Click  Begin  ->  Next  ->  Authorize
      3. Copy the ENTIRE command it shows you. It looks like:
             DISPLAY= /opt/google/chrome-remote-desktop/start-host \
               --code="4/xxxx..." --redirect-url="https://..." --name=...

    !! MULTI-ACCOUNT TRAP: if more than one Google account is signed into
       this browser, the OAuth redirect can bind the code to the WRONG
       account and start-host fails with "OAuth error". Either sign out of
       the extra accounts first, or use the account picker on that page.

    You'll be asked to set a 6+ digit PIN when the command runs (that's the
    PIN you'll type to connect later).
    ----------------------------------------------------------------------

PROMPT

START_HOST_CMD=""
while :; do
  printf '    Paste the full start-host command, then press Enter:\n    > '
  IFS= read -r START_HOST_CMD || die "No input received."
  START_HOST_CMD="${START_HOST_CMD#\$ }"            # tolerate a leading "$ "
  [[ "$START_HOST_CMD" == *start-host* && "$START_HOST_CMD" == *--code=* ]] && break
  warn "That doesn't look like a start-host command with a --code. Try again."
done

log "Enrolling this VM with Chrome Remote Desktop"
# Run as the (non-root) SSH user — NOT sudo. TTY allocated so the PIN prompt works.
remote_run_tty "$START_HOST_CMD" \
  || die "start-host failed. The most common cause is the multi-account OAuth trap above, or an expired code (they're single-use and short-lived). Re-do the headless flow for a fresh code and re-run this script."
info "CRD enrolled."

# =========================================================================== #
# PHASE 3 — Node 22+, Google Chrome, base build tools
# =========================================================================== #
log "Phase 3/5 — Installing Node ${NODE_MAJOR}.x, Google Chrome, and base tools"

PH3="$(mktemp)"
cat > "$PH3" <<PHASE3
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# build-essential is needed for native npm modules (e.g. better-sqlite3 via node-gyp)
sudo apt-get install -y git curl build-essential

# Node ${NODE_MAJOR}.x (>= 22.14 required by OpenClaw; Node 20 does NOT work)
curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
sudo apt-get install -y nodejs
echo "node: \$(node --version)  npm: \$(npm --version)"

# Google Chrome — system browser the human uses to open the OpenClaw dashboard
# inside CRD. (This is the human operator's system browser, separate from any
# browser an agent might drive itself.)
curl -L -o /tmp/google-chrome.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt-get install -y --fix-broken /tmp/google-chrome.deb
google-chrome --version || true

# Make Chrome the default browser. Two mechanisms so it sticks no matter how a
# link gets opened: xdg-mime (run as the SSH user, writes ~/.config/mimeapps.list;
# works without a running X session) covers xdg-open / desktop link handling, and
# update-alternatives covers tools that call x-www-browser / gnome-www-browser.
xdg-mime default google-chrome.desktop x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null || true
sudo update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
sudo update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true

echo "Phase 3 OK."
PHASE3
remote_run_script "$PH3" "openclaw-phase3.sh"

# =========================================================================== #
# PHASE 4 — Download VM plugin installer scripts
# =========================================================================== #
log "Phase 4/5 — Downloading VM plugin installer scripts"

PH4="$(mktemp)"
cat > "$PH4" <<PHASE4
#!/usr/bin/env bash
set -euo pipefail

repo_url="${PLUGIN_INSTALLER_REPO}"
dest_dir="\$HOME"
tmp_dir="\$(mktemp -d)"
trap 'rm -rf "\$tmp_dir"' EXIT

git clone --depth=1 "\$repo_url" "\$tmp_dir/repo"

found=0
while IFS= read -r -d '' script_path; do
  script_name="\$(basename "\$script_path")"
  cp "\$script_path" "\$dest_dir/\$script_name"
  chmod +x "\$dest_dir/\$script_name"
  found=1
done < <(find "\$tmp_dir/repo" -type f -name '*.sh' -print0)

if [[ "\$found" -eq 0 ]]; then
  echo "No .sh files found in \$repo_url." >&2
  exit 1
fi

echo "Downloaded shell scripts to \$dest_dir:"
find "\$dest_dir" -maxdepth 1 -type f -name '*.sh' -print | sort
echo "Phase 4 OK."
PHASE4
remote_run_script "$PH4" "openclaw-phase4.sh"

# =========================================================================== #
# PHASE 5 — Install OpenClaw (onboarding left to the operator)
# =========================================================================== #
log "Phase 5/5 — Installing OpenClaw"

PH5="$(mktemp)"
cat > "$PH5" <<'PHASE5'
#!/usr/bin/env bash
set -euo pipefail

# @latest is REQUIRED: the bare "openclaw" name is a squatted empty placeholder.
sudo npm install -g openclaw@latest

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw not on PATH after install." >&2
  exit 1
fi
echo "openclaw: $(openclaw --version)"

# The "coding" tools profile hides plugin/capability tools from the agent.
# Use the full tools profile so downloaded plugin installer scripts can expose tools.
if openclaw config get tools 2>/dev/null | grep -q '"profile"[[:space:]]*:[[:space:]]*"coding"'; then
  echo "setting tools.profile=full (coding hides plugin tools from the agent)"
  openclaw config set tools.profile full
fi

echo "Phase 5 (install) OK."
PHASE5
remote_run_script "$PH5" "openclaw-phase5.sh"

# OpenClaw onboarding is intentionally NOT run here — the operator runs
# `openclaw onboard --install-daemon` manually (note: NOT `openclaw configure`).

# =========================================================================== #
# Done — validation checklist
# =========================================================================== #
log "Template build complete"
cat <<DONE

    OpenClaw is installed but NOT onboarded — onboard it yourself:

      1. SSH works:
           gcloud compute ssh $VM_NAME ${GCLOUD_COMMON[*]}
      2. Desktop reachable:
           open https://remotedesktop.google.com/access , pick "$VM_NAME",
           enter your PIN.
      3. Inside the CRD desktop (or over SSH), confirm the install:
           openclaw --version          # should print a real version
      4. Run onboarding manually:
           openclaw onboard --install-daemon
         (For a template: pick the Dashboard / WebChat channel, and "Yes" to
         configure skills. NOT \`openclaw configure\`.)
      5. Then the dashboard:
           openclaw dashboard          # opens Chrome at http://127.0.0.1:18789/
      6. VM plugin installer shell scripts are in your VM home folder:
           ~/getplugin.sh
           ~/reinstall.sh

    Once onboarded, this box is a blank OpenClaw template. To put an agent in
    it, install a plugin (out of scope here), e.g. Kowalski for an end-to-end
    shakeout:
           openclaw plugins install <kowalski-repo>

DONE
