if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
    slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); \
    if [ -n "$slug" ]; then \
        concl=$(gh api --paginate "repos/$slug/commits/$(git rev-parse HEAD)/check-runs" \
            --jq '[.check_runs[]|select(.name=="CI passed")][0]|select(.status=="completed")|.conclusion' \
            2>/dev/null | head -n1); \
        case "$concl" in \
            failure|timed_out|cancelled|action_required) \
                echo "ERROR: 'CI passed' concluded '$concl' for HEAD."; \
                echo "  A release tag must not move, so tagging this commit"; \
                echo "  spends a version number. Fix main and cut the next one."; \
                exit 1 ;; \
            success) ;; \
            *) echo "tag-release: 'CI passed' has not concluded for HEAD" \
                    "— tagging ahead of it; the release will wait for it." ;; \
        esac; \
    fi; \
fi
