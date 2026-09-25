#!/bin/sh
# Xcode Cloud runs this after cloning, before the archive. Xcode 26 and
# later ship the Metal compiler as a separate download and the cloud image
# comes without it, so WindFlow.metal failed with "CompileMetalFile" on
# build 87 (2026-09-25). Fetch it first; the same command is what a fresh
# Mac needs (CLAUDE.md).
set -e
xcodebuild -downloadComponent MetalToolchain
