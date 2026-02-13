#!/bin/bash
set -euo pipefail

# Resolve script directory (works even when called via symlink)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Source shared utilities
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments (after sourcing common.sh which defines DRY_RUN default)
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Source all phases
source "$SCRIPT_DIR/lib/phase0_update.sh"
source "$SCRIPT_DIR/lib/phase1_kernel.sh"
source "$SCRIPT_DIR/lib/phase2_asusd.sh"
source "$SCRIPT_DIR/lib/phase3_hardware.sh"
source "$SCRIPT_DIR/lib/phase4_hyprland.sh"
source "$SCRIPT_DIR/lib/phase5_rogquick.sh"

# Track state
NEEDS_REBOOT=0
DONE=()
SKIPPED=()

# ── Main ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   ASUS ROG Flow Z13 (2025) — Linux Post-Install ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}║              [DRY-RUN MODE]                      ║${NC}"
    echo -e "${YELLOW}║  No changes will be made — showing what would run ║${NC}"
fi
echo ""

require_not_root
ensure_sudo
trap cleanup_sudo EXIT

# ── Phase 0 & 1: System + Kernel (reboot boundary) ──────────────────────

run_phase() {
    local num="$1" name="$2" check_fn="$3" run_fn="$4"

    echo ""
    echo -e "${BOLD}── Phase $num: $name ──${NC}"

    if $check_fn; then
        success "Already done — skipping."
        SKIPPED+=("Phase $num: $name")
        return 1  # signals "was skipped"
    fi

    if ask_yn "Set up $name?"; then
        $run_fn
        DONE+=("Phase $num: $name")
        return 0  # signals "was run"
    else
        info "Skipped by user."
        SKIPPED+=("Phase $num: $name (user skipped)")
        return 1
    fi
}

# Phases 0–1 (may require reboot)
run_phase 0 "System Update"   phase0_check phase0_run || true
run_phase 1 "Kernel & Drivers" phase1_check phase1_run || true

# Reboot gate after Phase 1
if [[ $NEEDS_REBOOT -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] A reboot would be recommended here. Continuing to show remaining phases..."
    else
        echo ""
        warn "A reboot is recommended to apply kernel/system changes."
        warn "After rebooting, re-run this script — completed phases will be auto-skipped."
        echo ""
        if ask_yn "Reboot now?"; then
            info "Rebooting..."
            sudo reboot
        else
            info "Please reboot manually, then re-run: ./install.sh"
            exit 0
        fi
    fi
fi

# Phases 2–5 (no reboot needed)
run_phase 2 "asusd Service Fix"       phase2_check phase2_run || true
run_phase 3 "Hardware Support"         phase3_check phase3_run || true
run_phase 4 "Hyprland Configuration"   phase4_check phase4_run || true
run_phase 5 "ROG Quick TDP Menu"       phase5_check phase5_run || true

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    Summary                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"

if [[ ${#DONE[@]} -gt 0 ]]; then
    echo -e "${GREEN}Completed:${NC}"
    for item in "${DONE[@]}"; do
        echo -e "  ${GREEN}✓${NC} $item"
    done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Skipped:${NC}"
    for item in "${SKIPPED[@]}"; do
        echo -e "  ${YELLOW}–${NC} $item"
    done
fi

echo ""
success "Setup complete. Enjoy your Z13!"
