#!/usr/bin/env bash
# fczd: ibmfree managed entry
exec /bin/bash "{{MANAGER_DIR}}/install.sh" --manage "$@"
