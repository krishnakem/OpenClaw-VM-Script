# OpenClaw GCP Agent VM Template

This repository contains a single provisioning script for creating a reusable
Google Cloud VM template for running OpenClaw-based agents.

The script builds a Debian 12 VM with:

- XFCE desktop environment
- Chrome Remote Desktop browser access
- Google Chrome
- Node.js 22.x
- Base build tools for native npm modules
- OpenClaw installed globally
- Chromium runtime libraries commonly needed by browser-driving agents
- Shell scripts from
  [`krishnakem/VM-Plugin-Installer-Script`](https://github.com/krishnakem/VM-Plugin-Installer-Script)
  downloaded into the VM

OpenClaw is installed but not onboarded. Agent plugins are also intentionally out
of scope. This repo is meant to create the blank infrastructure layer and stage
the plugin installer scripts: the box you can later onboard and customize for a
specific agent.

## Script

```sh
./setup-openclaw-vm.sh
```

Defaults:

- VM name: `experiment-claw`
- Zone: `us-west1-a`
- Machine type: `e2-standard-2`
- Image: Debian 12 from `debian-cloud`
- Boot disk: `30GB` `pd-balanced`

You can override the main VM settings:

```sh
./setup-openclaw-vm.sh \
  --name my-openclaw-vm \
  --zone us-west1-a \
  --machine-type e2-standard-2 \
  --project my-gcp-project
```

## Prerequisites

Install and authenticate the Google Cloud CLI on your local machine:

```sh
gcloud auth login
gcloud config set project <project-id>
```

The script runs from your local machine. It creates the VM with `gcloud`, then
uses `gcloud compute ssh` and `gcloud compute scp` to install software on the VM.

Chrome Remote Desktop does not provide an ARM Debian package, so ARM machine
types such as `t2a-*` and `c4a-*` are rejected. Use an x86_64 machine type.

## What It Does

The setup runs in five phases:

1. Creates or reuses the target GCP VM.
2. Installs XFCE, Chrome Remote Desktop, and Chromium runtime libraries.
3. Installs Node.js 22.x, Google Chrome, Git, curl, and build tools.
4. Downloads `*.sh` files from `krishnakem/VM-Plugin-Installer-Script` into
   the VM home folder and marks them executable.
5. Installs `openclaw@latest` globally with npm.

If an instance with the requested name already exists in the selected zone, the
script reuses it and skips VM creation.

## Manual Step: Chrome Remote Desktop

During setup, the script pauses for Chrome Remote Desktop enrollment.

Open this page on your local machine:

```text
https://remotedesktop.google.com/headless
```

Follow the prompts, authorize access, and copy the full `start-host` command.
Paste that command back into the script when prompted. You will also set a PIN
that you will use later to connect to the desktop.

If you are signed into multiple Google accounts in the same browser, the
enrollment flow can bind the code to the wrong account. Use the correct account
in the account picker or sign out of the extra accounts before generating the
command.

## After Setup

When the script completes, OpenClaw is installed but still needs onboarding.

SSH into the VM:

```sh
gcloud compute ssh experiment-claw --zone us-west1-a
```

Confirm OpenClaw is installed:

```sh
openclaw --version
```

Run onboarding manually:

```sh
openclaw onboard --install-daemon
```

The VM plugin installer shell scripts are available on the VM at:

```sh
~/getplugin.sh
~/reinstall.sh
```

For a reusable template, the script's guidance is to pick the Dashboard/WebChat
channel and configure skills when prompted.

Then launch the dashboard:

```sh
openclaw dashboard
```

The dashboard opens at:

```text
http://127.0.0.1:18789/
```

You can access the VM desktop from:

```text
https://remotedesktop.google.com/access
```

## Adding Agents

This repository does not install a specific agent. After the VM is provisioned
and OpenClaw is onboarded, install the relevant OpenClaw plugin for the agent you
want to run.

Example:

```sh
openclaw plugins install <plugin-repo>
```

## Notes

- `openclaw@latest` is installed explicitly because the bare `openclaw` npm name
  is not the intended package.
- Node.js 22.x is required; Node 20 is not sufficient for this setup.
- The default `e2-standard-2` machine type is chosen because smaller machines can
  struggle with Chromium and desktop workloads.
- The default 30 GB boot disk avoids running out of space after installing the
  desktop environment, Chrome, Node packages, and apt dependencies.
- If SSH is not reachable in a locked-down VPC, you may need to adapt the script
  to use IAP tunneling and add the required firewall rule.
