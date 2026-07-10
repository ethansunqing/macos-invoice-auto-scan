#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
build="$root/build"
install_dir="$HOME/Library/Application Support/InvoiceAutoCrop"
service_name="发票自动裁剪（图片+PDF）.workflow"
service_dir="$HOME/Library/Services/$service_name"

mkdir -p "$build" "$install_dir" "$HOME/Library/Services"

xcrun swiftc -O \
  -framework AppKit \
  -framework Vision \
  -framework CoreImage \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "$root/InvoiceAutoCrop.swift" \
  -o "$build/invoice-autocrop"

codesign --force --sign - "$build/invoice-autocrop"
install -m 755 "$build/invoice-autocrop" "$install_dir/invoice-autocrop"

rm -rf "$service_dir"
ditto "$root/QuickAction" "$service_dir"
plutil -lint "$service_dir/Contents/Info.plist" "$service_dir/Contents/document.wflow"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
touch "$service_dir"

echo "已安装：$service_dir"
