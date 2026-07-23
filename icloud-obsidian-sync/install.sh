#!/usr/bin/env bash
# Deploys the sync script + systemd units from this directory into place.
# Run AFTER `rclone config` has created the `iclouddrive` remote (see
# README.md steps 1-3) and after the baseline `rclone bisync --resync`
# (step 5) has completed successfully.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p ~/.local/bin ~/.local/share/obsidian-icloud-sync ~/.config/rclone ~/.config/systemd/user

cp "$SCRIPT_DIR/obsidian-icloud-sync.sh" ~/.local/bin/obsidian-icloud-sync.sh
chmod +x ~/.local/bin/obsidian-icloud-sync.sh

cp "$SCRIPT_DIR/obsidian-filters.txt" ~/.config/rclone/obsidian-filters.txt

cp "$SCRIPT_DIR/obsidian-icloud-sync.service" ~/.config/systemd/user/obsidian-icloud-sync.service
cp "$SCRIPT_DIR/obsidian-icloud-sync.timer" ~/.config/systemd/user/obsidian-icloud-sync.timer

systemctl --user daemon-reload
systemctl --user enable --now obsidian-icloud-sync.timer

echo "Installed. Run 'sudo loginctl enable-linger $USER' separately (needs your password)."
echo "Check status: systemctl --user list-timers obsidian-icloud-sync.timer"
