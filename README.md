# OpenClaw Agent VM - one-command GCP provisioner

**Turn a fresh GCP project into a browser-capable "agent box" with a single script.** Debian 12, XFCE reachable in the browser, Node 22, Chrome, and OpenClaw installed - the blank infrastructure layer I spin up every time I need to test an agent somewhere that isn't my laptop.

```bash
./setup-openclaw-vm.sh                       # sane defaults, one command
./setup-openclaw-vm.sh --name my-vm --zone us-west1-a --project my-gcp-project
```

---

## Why this exists

Every agent I build (Kowalski, Silicon Sandbox) eventually needs to run on a real machine with a real desktop and a real browser - not my laptop, which I want back. Standing that box up by hand is ~30 minutes of fiddly `apt`, Node version pain, and Chromium `.so` hunting. This script makes it repeatable and disposable: provision, test, tear down, repeat.

It builds the **infrastructure layer only**. OpenClaw is installed but *not* onboarded, and no specific agent plugin is installed - those are deliberate per-agent steps handled separately (see [VM-Plugin-Installer-Script](https://github.com/krishnakem/VM-Plugin-Installer-Script)). The output is a clean box you can onboard and specialize.

## What the box gets

- XFCE desktop + **Chrome Remote Desktop** (browser-based access, no SSH tunnel juggling)
- Google Chrome + the full set of Chromium runtime libraries browser-driving agents need
- Node.js 22.x (OpenClaw needs >= 22.14 - Node 20 will not work)
- Git, curl, build tools for native npm modules
- `openclaw@latest` installed globally, with `tools.profile` flipped `coding -> full` so plugin tools are visible to the agent
- The VM plugin-installer scripts staged in the home folder, ready to pull agents in

## How it runs

The script runs on **your laptop**, not inside the VM. Phase 1 creates the instance with `gcloud`; phases 2-5 install software over `gcloud compute ssh`/`scp` (chosen deliberately - OS Login passwordless sudo is reliable over gcloud SSH but can prompt for an absent password inside the CRD desktop).

1. Create or reuse the target VM
2. Install XFCE, Chrome Remote Desktop, Chromium runtime libs
3. Install Node 22, Chrome, Git, curl, build tools
4. Download the plugin-installer `*.sh` scripts into the VM
5. Install OpenClaw globally and set `tools.profile=full`

If a VM with the requested name already exists in the zone, it's reused and creation is skipped.

## Defaults

| Setting | Default | Notes |
| --- | --- | --- |
| Name | `experiment-claw` | |
| Zone | `us-west1-a` | Oregon |
| Machine type | `e2-standard-2` | 2 vCPU / 8 GB - `e2-medium` (4 GB) crashes Chromium |
| Image | Debian 12 (`debian-cloud`) | amd64 |
| Boot disk | 30 GB `pd-balanced` | 10 GB fills up fast (Chromium + node_modules + apt + DE) |

**x86_64 only.** Chrome Remote Desktop ships no ARM Debian package, so ARM types (`t2a-*`, `c4a-*`) are rejected up front.

## Prerequisites

```bash
gcloud auth login
gcloud config set project <project-id>
```

## The one manual step

CRD enrollment needs a human: you paste a `start-host --code="..."` command from [remotedesktop.google.com/headless](https://remotedesktop.google.com/headless) (Google won't mint that code for a script). The script prints a checklist at the end covering this and `openclaw onboard --install-daemon`.

## License

See repository.
