#!/bin/bash
#
# Build script for AudioScribe menu bar app
#

set -e

cd "$(dirname "$0")"

echo "Building AudioScribeApp..."
swift build -c release

echo "Copying binary to app bundle..."
cp .build/release/AudioScribeApp AudioScribeApp.app/Contents/MacOS/

echo "Done!"
echo ""
echo "To run the app:"
echo "  open AudioScribeApp/AudioScribeApp.app"
echo ""
echo "To use CLI control:"
echo "  ./ascribe-ctl status"
echo "  ./ascribe-ctl start --output recording.wav"
echo "  ./ascribe-ctl stop"
