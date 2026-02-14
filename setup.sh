#!/usr/bin/env bash
#
# Copyright (c) 2025 William Collins. Licensed under the MIT License. See LICENSE.
#
# setup.sh - Install Claude Code skills
#
# Usage: ./setup.sh
#
# This script installs all skills to ~/.claude/skills/:
# - prompt-stack: branch-trunk, pr-trunk, reset-trunk, etc.
# - feature-dev: feature-dev
# - feature-scout: feature-scout
# - frontend-design: frontend-design
# - ralph-wiggum: ralph-loop, cancel-ralph, help
#
# Safe to run multiple times (idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
PLUGINS_DIR="${SCRIPT_DIR}/plugins"

# Bundled plugins to install
BUNDLED_PLUGINS=(
    "feature-dev"
    "feature-scout"
    "frontend-design"
    "ralph-wiggum"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[+]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[-]${NC} $1"
}

# Create directory symlink, handling existing links appropriately
link_dir() {
    local src="$1"
    local dest="$2"

    if [[ -L "$dest" ]]; then
        local current_target
        current_target="$(readlink "$dest")"
        if [[ "$current_target" == "$src" ]]; then
            info "Already linked: $(basename "$dest")"
        else
            rm "$dest"
            ln -s "$src" "$dest"
            info "Updated: $(basename "$dest")"
        fi
    elif [[ -e "$dest" ]]; then
        warn "Skipping $(basename "$dest"): regular file/directory exists"
    else
        ln -s "$src" "$dest"
        info "Linked: $(basename "$dest")"
    fi
}

# Create file symlink, handling existing links appropriately
link_file() {
    local src="$1"
    local dest="$2"

    if [[ -L "$dest" ]]; then
        local current_target
        current_target="$(readlink "$dest")"
        if [[ "$current_target" == "$src" ]]; then
            info "Already linked: $(basename "$dest")"
        else
            rm "$dest"
            ln -s "$src" "$dest"
            info "Updated: $(basename "$dest")"
        fi
    elif [[ -e "$dest" ]]; then
        warn "Skipping $(basename "$dest"): regular file exists"
    else
        ln -s "$src" "$dest"
        info "Linked: $(basename "$dest")"
    fi
}

# For flat .md plugin files: creates ~/.claude/skills/<name>/ directory
# and symlinks the .md as SKILL.md inside it
link_plugin_skill() {
    local src="$1"
    local skill_name="$2"
    local dest_dir="$SKILLS_DIR/$skill_name"
    local dest="$dest_dir/SKILL.md"

    mkdir -p "$dest_dir"

    if [[ -L "$dest" ]]; then
        local current_target
        current_target="$(readlink "$dest")"
        if [[ "$current_target" == "$src" ]]; then
            info "Already linked: $skill_name"
        else
            rm "$dest"
            ln -s "$src" "$dest"
            info "Updated: $skill_name"
        fi
    elif [[ -e "$dest" ]]; then
        warn "Skipping $skill_name: regular file exists"
    else
        ln -s "$src" "$dest"
        info "Linked: $skill_name"
    fi
}

# Remove prompt-stack-owned symlinks from legacy locations
# (~/.claude/commands/ and ~/.claude/skills/ flat .md files)
cleanup_legacy() {
    local cleaned=0

    # Clean up flat .md symlinks in ~/.claude/commands/
    if [[ -d "$CLAUDE_DIR/commands" ]]; then
        for link in "$CLAUDE_DIR/commands"/*.md; do
            [[ -L "$link" ]] || continue
            local target
            target="$(readlink "$link")"
            if [[ "$target" == "$SCRIPT_DIR/"* ]]; then
                rm "$link"
                warn "Removed legacy: commands/$(basename "$link")"
                ((cleaned++)) || true
            fi
        done
    fi

    # Clean up flat .md symlinks in ~/.claude/skills/
    if [[ -d "$SKILLS_DIR" ]]; then
        for link in "$SKILLS_DIR"/*.md; do
            [[ -L "$link" ]] || continue
            local target
            target="$(readlink "$link")"
            if [[ "$target" == "$SCRIPT_DIR/"* ]]; then
                rm "$link"
                warn "Removed legacy: skills/$(basename "$link")"
                ((cleaned++)) || true
            fi
        done
    fi

    # Clean up stale directory symlinks in ~/.claude/skills/
    if [[ -d "$SKILLS_DIR" ]]; then
        for link in "$SKILLS_DIR"/*/; do
            link="${link%/}"
            [[ -L "$link" ]] || continue
            local target
            target="$(readlink "$link")"
            if [[ "$target" == "$SCRIPT_DIR/"* ]] && [[ ! -e "$link" ]]; then
                rm "$link"
                warn "Removed stale: skills/$(basename "$link")"
                ((cleaned++)) || true
            fi
        done
    fi

    if [[ $cleaned -gt 0 ]]; then
        info "Cleaned up $cleaned legacy/stale symlink(s)"
        echo
    fi
}

main() {
    echo "Installing Claude Code plugins and skills..."
    echo

    # Create directories
    mkdir -p "$CLAUDE_DIR"
    mkdir -p "$SKILLS_DIR"

    # Remove legacy flat symlinks and stale links from previous installations
    cleanup_legacy

    # Link prompt-stack skills to ~/.claude/skills/
    # Finds SKILL.md files and symlinks their parent directories
    echo "Installing prompt-stack skills..."
    local skill_count=0
    while IFS= read -r -d '' skill; do
        local skill_dir
        skill_dir="$(dirname "$skill")"
        local skill_name
        skill_name="$(basename "$skill_dir")"
        link_dir "$skill_dir" "$SKILLS_DIR/$skill_name"
        ((skill_count++)) || true
    done < <(find "$SCRIPT_DIR/skills" -name "SKILL.md" -type f -print0 2>/dev/null)
    if [[ $skill_count -eq 0 ]]; then
        warn "No skill files found in $SCRIPT_DIR/skills/"
    fi
    echo

    # Install bundled plugin skills to ~/.claude/skills/
    # Supports SKILL.md directories (symlinked as directories) and
    # flat .md files (wrapped in a directory with SKILL.md symlink)
    echo "Installing plugin skills..."
    for plugin in "${BUNDLED_PLUGINS[@]}"; do
        local plugin_path="$PLUGINS_DIR/$plugin"
        local skills_path=""

        # Check for skills/ directory first, then commands/ for legacy support
        if [[ -d "$plugin_path/skills" ]]; then
            skills_path="$plugin_path/skills"
        elif [[ -d "$plugin_path/commands" ]]; then
            skills_path="$plugin_path/commands"
        fi

        if [[ -n "$skills_path" ]]; then
            # Handle SKILL.md files (directory-based pattern) — symlink the directory
            while IFS= read -r -d '' skill; do
                local skill_dir
                skill_dir="$(dirname "$skill")"
                local skill_name
                skill_name="$(basename "$skill_dir")"
                link_dir "$skill_dir" "$SKILLS_DIR/$skill_name"
            done < <(find "$skills_path" -name "SKILL.md" -type f -print0 2>/dev/null)

            # Handle flat .md files — wrap in a directory with SKILL.md symlink
            while IFS= read -r -d '' skill; do
                local skill_name
                skill_name="$(basename "$skill" .md)"
                link_plugin_skill "$skill" "$skill_name"
            done < <(find "$skills_path" -maxdepth 1 -name "*.md" ! -name "SKILL.md" -type f -print0 2>/dev/null)
        fi
    done
    echo

    # Link CLAUDE.md for global configuration
    echo "Linking global configuration..."
    if [[ -f "$SCRIPT_DIR/CLAUDE.md" ]]; then
        link_file "$SCRIPT_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
    else
        warn "No CLAUDE.md found in $SCRIPT_DIR"
    fi

    echo
    echo -e "${GREEN}Installation complete!${NC}"
    echo
    echo "Skills installed:"
    for skill_dir in "$SKILLS_DIR"/*/; do
        [[ -e "${skill_dir}SKILL.md" ]] || continue
        echo "  /$(basename "$skill_dir")"
    done
    echo
    echo "Restart Claude Code to load changes."
}

main "$@"
