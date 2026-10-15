#!/bin/bash
# Kitflo installer:  curl -fsSL https://raw.githubusercontent.com/harshkit/kitflo/main/install.sh | bash
set -euo pipefail

REPO="harshkit/kitflo"
MODEL_DIR="$HOME/Library/Application Support/Kitflo/models"
MODEL="$MODEL_DIR/qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
APP_DIR="$HOME/Applications"

say() { printf '\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Kitflo runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "Kitflo needs an Apple Silicon Mac (M1 or newer)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || die "Kitflo needs macOS 26 (Tahoe) or newer."

if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  say "Installing Homebrew (it may ask for your password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
BREW=$(command -v brew || echo /opt/homebrew/bin/brew)

say "Installing llama.cpp (local AI engine)"
"$BREW" list llama.cpp >/dev/null 2>&1 || "$BREW" install llama.cpp

# Kitflo was called OpenFlo before 1.2: carry the downloaded model over instead of fetching it again.
OLD_DIR="$HOME/Library/Application Support/OpenFlo"
if [ -d "$OLD_DIR" ] && [ ! -d "$HOME/Library/Application Support/Kitflo" ]; then
  mv "$OLD_DIR" "$HOME/Library/Application Support/Kitflo"
fi

if [ ! -s "$MODEL" ]; then
  say "Downloading the cleanup model (~1 GB, one time)"
  mkdir -p "$MODEL_DIR"
  curl -fL --progress-bar -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi

say "Downloading Kitflo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/Kitflo.zip" "https://github.com/$REPO/releases/latest/download/Kitflo.zip"
pkill -f "Kitflo.app/Contents/MacOS/Kitflo" 2>/dev/null || true
pkill -f "OpenFlo.app/Contents/MacOS/OpenFlo" 2>/dev/null || true   # the old name
rm -rf "$APP_DIR/OpenFlo.app"
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Kitflo.app"
ditto -x -k "$TMP/Kitflo.zip" "$APP_DIR"

say "Done! Opening Kitflo"
echo "  1. Allow Microphone and Accessibility when asked."
echo "  2. System Settings → Keyboard → 'Press 🌐 key to' → Do Nothing."
echo "  3. Click in any text field, hold fn and talk."
open "$APP_DIR/Kitflo.app"
