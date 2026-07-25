#!/usr/bin/env bash
# Deploys the sync script, filters and systemd units from this directory.
# Run AFTER `rclone config` has created the `gdrive` remote with
# root_folder_id pinned to the Learning Turkish folder (README steps 1-4),
# and after the import-format check in step 5 has passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p ~/.local/bin ~/.local/share/gdrive-turkish-sync ~/.config/rclone ~/.config/systemd/user
mkdir -p ~/Documents/"Obsidian Vault - Learning Turkish"

cp "$SCRIPT_DIR/gdrive-turkish-sync.sh" ~/.local/bin/gdrive-turkish-sync.sh
chmod +x ~/.local/bin/gdrive-turkish-sync.sh

cp "$SCRIPT_DIR/turkish-push-assets.txt" ~/.config/rclone/turkish-push-assets.txt
cp "$SCRIPT_DIR/turkish-push-md.txt" ~/.config/rclone/turkish-push-md.txt

cp "$SCRIPT_DIR/gdrive-turkish-sync.service" ~/.config/systemd/user/gdrive-turkish-sync.service
cp "$SCRIPT_DIR/gdrive-turkish-sync.timer" ~/.config/systemd/user/gdrive-turkish-sync.timer

systemctl --user daemon-reload
systemctl --user enable --now gdrive-turkish-sync.timer

echo "Installed."
echo
echo "First run:   systemctl --user start gdrive-turkish-sync.service"
echo "Watch it:    tail -f ~/.local/share/gdrive-turkish-sync/sync.log"
echo
echo "Then in Obsidian: 'Open folder as vault' ->"
echo "  ~/Documents/Obsidian Vault - Learning Turkish"
echo "This is a standalone vault. It is NOT touched by the iCloud sync."
