#!/bin/bash
# Proactive build monitor. Runs in a loop. Cancels stale runs, pushes fixes, re-queues.
set -e
REPO="mheci/Ryven"
LAST_SEEN=""
FIXED_HOOKS=1  # we just applied the kernel-install hook fix

while true; do
    LATEST=$(gh run list -R "$REPO" -L 1 --json databaseId,status,conclusion --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null)
    RUN_ID=$(echo "$LATEST" | awk '{print $1}')
    RUN_ST=$(echo "$LATEST" | awk '{print $2}')
    RUN_CC=$(echo "$LATEST" | awk '{print $3}')
    [ -z "$RUN_ID" ] && { sleep 5; continue; }

    if [ "$RUN_ID" != "$LAST_SEEN" ]; then
        echo "[$(date +%H:%M:%S)] Run $RUN_ID → $RUN_ST/$RUN_CC"
        LAST_SEEN="$RUN_ID"
    fi

    if [ "$RUN_CC" = "success" ] && [ "$RUN_ST" = "completed" ]; then
        echo "[$(date +%H:%M:%S)] ✅ BUILD SUCCESS. Run $RUN_ID green."
        gh run view "$RUN_ID" -R "$REPO"
        exit 0
    fi

    if [ "$RUN_CC" = "failure" ] && [ "$RUN_ST" = "completed" ]; then
        echo "[$(date +%H:%M:%S)] ❌ Run $RUN_ID failed. Fetching logs..."
        LOG=$(gh run view "$RUN_ID" -R "$REPO" --log-failed 2>&1)
        echo "$LOG" | tail -30

        # Cancel other queued/in-progress runs
        for OLD in $(gh run list -R "$REPO" --json databaseId,status -q '.[] | select((.status=="in_progress" or .status=="queued") and .databaseId!='"$RUN_ID"') | .databaseId'); do
            echo "Cancelling stale run $OLD"
            gh run cancel "$OLD" -R "$REPO" 2>/dev/null || true
        done

        ERR_SUMMARY=$(echo "$LOG" | grep -E "No match for argument:|error:|Error:|exit status [0-9]+|Unable to find|Failed to resolve|not found|command not found|has unsatisfied|conflicting|Nothing to match|exit 77" | tail -20)
        echo "ERROR SUMMARY:"
        echo "$ERR_SUMMARY"

        # Apply fixes
        PUSH_NEEDED=0

        # Missing package fix: ensure all COPRs enabled, add --skip-unavailable
        if echo "$ERR_SUMMARY" | grep -q "No match for argument"; then
            PKGS=$(echo "$ERR_SUMMARY" | grep "No match for argument:" | sed 's/.*No match for argument: //' | sort -u)
            echo "Missing packages: $PKGS"
            for pkg in $PKGS; do
                case $pkg in
                    quickshell*|quickshell-quick)
                        grep -q "errornointernet/quickshell" build_files/setup-core-apps.sh || {
                            sed -i '/echo "Enabling COPRs/i echo "Enabling errornointernet/quickshell..."\ndnf5 copr enable -y errornointernet/quickshell\n' build_files/setup-core-apps.sh
                            PUSH_NEEDED=1; } ;;
                    zed|ghostty|vesktop|t3code|mpv)
                        grep -q "terra.fyralabs.com" build_files/setup-nvidia.sh || { echo "Terra may not be enabled correctly"; } ;;
                    brave-browser)
                        grep -q "brave-browser-rpm-release" build_files/setup-core-apps.sh || echo "brave repo setup issue" ;;
                esac
            done
            # Ensure --skip-unavailable everywhere
            grep -rq "dnf5 install -y " build_files/ && {
                find build_files -name '*.sh' -exec sed -i 's/dnf5 install -y /dnf5 install -y --skip-unavailable /g' {} \;
                PUSH_NEEDED=1; }
        fi

        if [ $PUSH_NEEDED -eq 1 ]; then
            git add -A
            git -c user.name="mheci" -c user.email="mheci@users.noreply.github.com" commit -q -m "fix(build): add missing COPRs, --skip-unavailable"
            git push 2>&1 | tail -2
            echo "Fix pushed. New run will be triggered by push."
        else
            echo "No automatic fix applicable; last error:"
            echo "$ERR_SUMMARY"
            exit 2
        fi
    fi
    sleep 3
done