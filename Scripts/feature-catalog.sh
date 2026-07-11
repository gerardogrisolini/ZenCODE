#!/usr/bin/env bash

# Bundled SwiftPM feature products for installer targets. Keep platform-specific
# product sets here so build and copy loops in the installers use one catalog.
zencode_select_feature_products() {
    local platform="$1"

    case "$platform" in
        macos)
            FEATURE_PRODUCTS=(
                "search-tools-feature"
                "web-tools-feature"
                "git-tools-feature"
                "swift-tools-feature"
                "xcode-tools-feature"
                "figma-tools-feature"
                "jira-tools-feature"
            )
            ;;
        linux)
            FEATURE_PRODUCTS=(
                "search-tools-feature"
                "web-tools-feature"
                "git-tools-feature"
                "xcode-tools-feature"
                "figma-tools-feature"
                "jira-tools-feature"
            )
            ;;
        *)
            echo "Error: unknown installer platform '${platform}'." >&2
            return 1
            ;;
    esac
}
