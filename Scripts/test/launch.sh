#!/bin/bash
# Starts the installed Sayso for testing: debug hooks on, a local mock API, no real key, no permission prompts.
# Usage: Scripts/test/launch.sh [api-key] [api-base]     (an empty key simulates "no key yet")
pkill -x Sayso; sleep 0.6
(env SAYSO_DEBUG_HOOKS=1 ${SAYSO_TEST_PASTEBOARD:+SAYSO_TEST_PASTEBOARD=$SAYSO_TEST_PASTEBOARD} SAYSO_API_BASE=${2:-http://127.0.0.1:8765} SAYSO_API_KEY=${1-test-key} \
  nohup /Applications/Sayso.app/Contents/MacOS/Sayso --no-prompts >/dev/null 2>&1 &)
sleep 1.5
