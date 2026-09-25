#!/bin/sh
# Xcode Cloud runs this after cloning. Nothing in the app needs the Metal
# compiler any more (the wind shader is compiled on the device, see
# WindFlowView.swift), so this only makes sure the image's Metal toolchain
# is present for anything that might come later, and never fails the
# build: on 2026-09-25 the image answered "already imported" with exit 70.
xcodebuild -downloadComponent MetalToolchain || true
exit 0
