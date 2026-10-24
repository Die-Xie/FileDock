#!/bin/zsh
# Opt-in: briefly opens disposable native pickers, then cancels them automatically.
set -eu
cd "${0:A:h}"
mkdir -p .build
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/WindowPresentation.swift Tests/ModalPanelLifecycleTests.swift \
    -o .build/modal-panel-lifecycle-tests -framework AppKit -framework CoreGraphics
.build/modal-panel-lifecycle-tests
