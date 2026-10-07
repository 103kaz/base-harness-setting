#!/bin/bash
# 個人共通 PostToolUse(Edit|Write): .tf / .tfvars を編集したら terraform fmt をかける。
f="$(jq -r '.tool_response.filePath // .tool_input.file_path // ""')"
case "$f" in
  *.tf|*.tfvars) command -v terraform >/dev/null && terraform fmt "$f" >/dev/null ;;
esac
exit 0
