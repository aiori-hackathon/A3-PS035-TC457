#!/usr/bin/env bash
# Docker Engine + Containerlab + FRR image setup for WSL2 Ubuntu (v2).
# Safe to re-run: steps that are already done are skipped.
# Run inside WSL:  bash setupdocker.sh
set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as your normal user (not root). The script uses sudo where needed."
  exit 1
fi

NEED_RESTART=0

# ---------- 1. Docker Engine ----------
if command -v docker >/dev/null 2>&1; then
  echo "==> Docker already installed: $(docker --version)"
else
  set -e
  echo "==> Installing prerequisites"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release

  echo "==> Adding Docker's official apt repository"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  echo "==> Installing Docker Engine"
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  set +e
fi

# ---------- 2. Start Docker ----------
if pidof systemd >/dev/null 2>&1; then
  sudo systemctl enable --now docker
else
  echo "==> systemd not active; enabling it for the next WSL restart"
  if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    printf "[boot]\nsystemd=true\n" | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  sudo service docker start || true
  NEED_RESTART=1
fi

# ---------- 3. Containerlab ----------
if command -v containerlab >/dev/null 2>&1; then
  echo "==> Containerlab already installed: $(containerlab version 2>/dev/null | grep -m1 version)"
else
  echo "==> Installing Containerlab"
  bash -c "$(curl -sL https://get.containerlab.dev)"
fi

# ---------- 4. Groups ----------
echo "==> Adding $USER to docker and clab_admins groups"
sudo usermod -aG docker "$USER"
getent group clab_admins >/dev/null 2>&1 || sudo groupadd clab_admins
sudo usermod -aG clab_admins "$USER"

# ---------- 5. FRR image (non-fatal) ----------
echo "==> Pulling FRR image"
FRR_IMAGE=""
for img in frrouting/frr:latest quay.io/frrouting/frr:latest; do
  if sudo docker pull "$img"; then
    FRR_IMAGE="$img"
    break
  fi
  echo "   could not pull $img, trying next source"
done

if [ -n "$FRR_IMAGE" ]; then
  DIGEST=$(sudo docker image inspect "$FRR_IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null)
  echo
  echo "FRR image ready: $FRR_IMAGE"
  echo "Pin this exact image in topo.clab.yml so all teammates match:"
  echo "  image: ${DIGEST:-$FRR_IMAGE}"
else
  echo
  echo "WARNING: could not pull any FRR image. Check your internet/DNS and re-run."
fi

# ---------- 6. Done ----------
echo
echo "Setup finished."
if [ "$NEED_RESTART" = "1" ]; then
  echo "systemd was just enabled: in PowerShell run  wsl --shutdown  then reopen Ubuntu."
else
  echo "Close and reopen your Ubuntu terminal so the new groups apply."
fi
echo
echo "Then verify with:"
echo "  docker run --rm hello-world"
echo "  containerlab version"
echo "  sudo tc qdisc add dev lo root netem delay 10ms && echo NETEM_OK; sudo tc qdisc del dev lo root"
