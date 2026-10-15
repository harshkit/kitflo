#!/bin/bash
# OpenFlo installer:  curl -fsSL https://raw.githubusercontent.com/harshkit/openflo/main/install.sh | bash
set -euo pipefail

REPO="harshkit/openflo"
MODEL_DIR="$HOME/Library/Application Support/OpenFlo/models"
MODEL="$MODEL_DIR/qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
APP_DIR="$HOME/Applications"

say() { printf '\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "OpenFlo runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "OpenFlo needs an Apple Silicon Mac (M1 or newer)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || die "OpenFlo needs macOS 26 (Tahoe) or newer."

if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  say "Installing Homebrew (it may ask for your password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
BREW=$(command -v brew || echo /opt/homebrew/bin/brew)

say "Installing llama.cpp (local AI engine)"
"$BREW" list llama.cpp >/dev/null 2>&1 || "$BREW" install llama.cpp

if [ ! -s "$MODEL" ]; then
  say "Downloading the cleanup model (~1 GB, one time)"
  mkdir -p "$MODEL_DIR"
  curl -fL --progress-bar -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi

say "Downloading OpenFlo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/OpenFlo.zip" "https://github.com/$REPO/releases/latest/download/OpenFlo.zip"
pkill -f "OpenFlo.app/Contents/MacOS/OpenFlo" 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/OpenFlo.app"
ditto -x -k "$TMP/OpenFlo.zip" "$APP_DIR"

say "Done! Opening OpenFlo"
echo "  1. Allow Microphone and Accessibility when asked."
echo "  2. System Settings → Keyboard → 'Press 🌐 key to' → Do Nothing."
echo "  3. Click in any text field, hold fn and talk."
open "$APP_DIR/OpenFlo.app"
