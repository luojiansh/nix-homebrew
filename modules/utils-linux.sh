#!/bin/bash

# Linux-specific utilities for Homebrew setup
# BSD 2-Clause License
# Copyright (c) 2009-present, Homebrew contributors

# Uses:
# - HOMEBREW_PREFIX
# - HOMEBREW_LIBRARY
# - NIX_HOMEBREW_UID
# - NIX_HOMEBREW_GID

# Linux-specific tool paths
STAT_PRINTF=("stat" "--printf")
PERMISSION_FORMAT="%a"

CHMOD=("chmod")
CHOWN=("chown")
CHGRP=("chgrp")
MKDIR=("mkdir" "-p")
TOUCH=("touch")
INSTALL=("install" -d -o "root" -g "root" -m "0755")
