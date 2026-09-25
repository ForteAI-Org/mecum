#!/bin/sh
#
#  embed-helper.sh
#  Mecum
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
#
#  Copies the `mecum-bridge` helper into Contents/Helpers and makes it load the
#  frameworks embedded in Contents/Frameworks, so a copied or archived app runs it.

set -eu

# An archive links the product from UninstalledProducts into the products folder,
# and the script sandbox reads only a declared path, never a link's target.
source="$BUILT_PRODUCTS_DIR/mecum-bridge"
if [ -L "$source" ]; then source="$UNINSTALLED_PRODUCTS_DIR/$PLATFORM_NAME/mecum-bridge"; fi
helper="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/mecum-bridge"

# The script sandbox lets install_name_tool write its scratch files only under TEMP_DIR.
work="$TEMP_DIR/embed-helper/mecum-bridge"
mkdir -p "$(dirname "$work")"
cp -f "$source" "$work"

# SwiftPM links the helper with an absolute rpath into this build directory,
# which a copied app does not have and which would shadow the embedded frameworks.
# Only that one goes: /usr/lib/swift is the system's. A universal helper lists each
# rpath once per architecture and one delete takes it from both, hence the sort.
otool -l "$work" \
    | awk '/cmd LC_RPATH/ { found = 1 }
           found && /^ *path / { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; found = 0 }' \
    | sort -u \
    | while IFS= read -r path; do
        case "$path" in
            "$BUILD_DIR"/*) install_name_tool -delete_rpath "$path" "$work" ;;
        esac
    done
install_name_tool -add_rpath @loader_path/../Frameworks "$work"

# The rpath edit invalidates the linker's signature.
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$work"

mkdir -p "$(dirname "$helper")"
cp -f "$work" "$helper"
