#!/bin/bash

# Darwin (macOS) specific utilities for Homebrew setup
# BSD 2-Clause License
# Copyright (c) 2009-present, Homebrew contributors

# Uses:
# - HOMEBREW_PREFIX
# - HOMEBREW_LIBRARY
# - NIX_HOMEBREW_UID
# - NIX_HOMEBREW_GID

# Darwin-specific tool paths
STAT_PRINTF=("/usr/bin/stat" "-f")
PERMISSION_FORMAT="%A"

CHMOD=("/bin/chmod")
CHOWN=("/usr/sbin/chown")
CHGRP=("/usr/bin/chgrp")
MKDIR=("/bin/mkdir" "-p")
TOUCH=("/usr/bin/touch")
INSTALL=("/usr/bin/install" -d -o "root" -g "wheel" -m "0755")
