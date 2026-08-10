#!/bin/zsh
script_dir=${0:A:h}
cd "$script_dir/.." || exit 1
printf '\033]0;CopyCo Local Verification\007'
clear
echo "CopyCo Local Verification"
echo "========================="
echo "Shortcut: Option+Command+C"
echo "Languages: 简体中文 / English"
echo "Bundle: build/CopyCo.app"
echo
echo "$ swift test --filter HotKeyConfigurationTests"
swift test --filter HotKeyConfigurationTests
echo
echo "$ swift build -c release"
swift build -c release
echo
echo "$ scripts/build-app.sh"
scripts/build-app.sh
echo
echo "Running process:"
pgrep -alf CopyCo || echo "CopyCo is not running"
echo
echo "Press any key to close this verification console."
read -k 1
