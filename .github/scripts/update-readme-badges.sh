#!/bin/bash
# Updates the NVIDIA/Ubuntu version and release status tags in README.md

set -e

README="README.md"

# Use env vars set by workflow
NV_VERSION="${NV_VERSION:-580.89.05}"
UBUNTU_VERSION="${UBUNTU_VERSION:-25.04}"
RELEASE_STATUS="${RELEASE_STATUS:-passed}"

# Replace the tags in the README
sed -i 's/`<!--NV_VERSION-->`[^|]*/`<!--NV_VERSION-->` '
