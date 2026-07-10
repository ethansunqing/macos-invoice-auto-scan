#!/bin/zsh
set -euo pipefail

install_dir="$HOME/Library/Application Support/InvoiceAutoCrop"
service_dir="$HOME/Library/Services/发票自动裁剪（图片+PDF）.workflow"

rm -rf "$install_dir" "$service_dir"
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "发票自动裁剪已卸载。"
