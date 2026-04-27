#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0
skip=0

run_step() {
    local title="$1"
    shift

    echo ""
    echo -e "${YELLOW}▶ $title${NC}"
    printf "  Press Enter to run, s to skip, q to quit: "
    read -r choice

    case "$choice" in
        s|S)
            echo -e "  ${YELLOW}skipped${NC}"
            ((skip++)) || true
            return 0
            ;;
        q|Q)
            echo "Quit."
            exit 0
            ;;
    esac

    if "$@"; then
        echo -e "  ${GREEN}✓ passed${NC}"
        ((pass++)) || true
    else
        echo -e "  ${RED}✗ failed${NC}"
        ((fail++)) || true
    fi
}

# Step 1: byte-compile
run_step "Byte-compile all source files" \
    emacs -batch -L . -f batch-byte-compile \
        skssh-config.el skssh-core.el skssh-ui.el skssh-sftp.el skssh.el skssh-test.el

# Step 2: install package-lint env
run_step "Install package-lint into /tmp/melpa-lint-env" \
    emacs -batch \
        --eval "(setq user-emacs-directory \"/tmp/melpa-lint-env/\")" \
        --eval "(setq package-user-dir \"/tmp/melpa-lint-env/elpa\")" \
        --eval "(require 'package)" \
        --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
        --eval "(package-initialize)" \
        --eval "(package-refresh-contents)" \
        --eval "(package-install 'package-lint)"

# Step 3: package-lint
run_step "Run package-lint" \
    emacs -batch -L . \
        --eval "(setq user-emacs-directory \"/tmp/melpa-lint-env/\")" \
        --eval "(setq package-user-dir \"/tmp/melpa-lint-env/elpa\")" \
        --eval "(require 'package)" \
        --eval "(package-initialize)" \
        -l package-lint \
        -f package-lint-batch-and-exit \
        skssh.el skssh-config.el skssh-core.el skssh-ui.el skssh-sftp.el

# Step 4: checkdoc
run_step "Run checkdoc" \
    emacs -batch --eval "(progn
        (require 'checkdoc)
        (dolist (f '(\"skssh-config.el\" \"skssh-core.el\" \"skssh-ui.el\" \"skssh-sftp.el\" \"skssh.el\"))
          (checkdoc-file f)))"

# Step 5: clean
run_step "Clean /tmp/melpa-lint-env and .elc files" \
    bash -c "rm -rf /tmp/melpa-lint-env && rm -f ./*.elc"

# Summary
echo ""
echo "────────────────────────────"
echo -e "  ${GREEN}passed: $pass${NC}  ${RED}failed: $fail${NC}  ${YELLOW}skipped: $skip${NC}"
echo "────────────────────────────"

[[ $fail -eq 0 ]]
