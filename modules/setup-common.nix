# Shared Homebrew setup script generator
# Platform wrappers pass the small OS-specific differences.

{ lib, pkgs, config }:
{
  utilsFile,
  gidScript,
  lnForceFunction,
  detectRepositorySnippet,
  postSetupSnippet ? "",
}:
let
  cfg = config.nix-homebrew;
  tools = cfg._tools;
  nixMarker = cfg._nixMarker;
  brew = cfg._brewPackage;
  makeBinBrew = cfg.makeBinBrew;

  setupPrefix = prefix: ''
    HOMEBREW_PREFIX="${prefix.prefix}"
    HOMEBREW_LIBRARY="${prefix.library}"

    >&2 echo "setting up Homebrew ($HOMEBREW_PREFIX)..."

    HOMEBREW_CODE="$HOMEBREW_LIBRARY/Homebrew"
    if is_occupied "$HOMEBREW_CODE"; then
      # Probably an existing installation
      warn "An existing $HOMEBREW_CODE is in the way"
      warn "$HOMEBREW_PREFIX seems to contain an existing copy of Homebrew."

      ${detectRepositorySnippet}

      if [[ -z "${toString cfg.autoMigrate}" ]]; then
        ohai "There are two ways to proceed:"
        ohai "1. Use the official uninstallation script to remove Homebrew (you will lose all taps and installed packages)"
        ohai "2. Set nix-homebrew.autoMigrate = true; to allow nix-homebrew to migrate the installation"

        ohai "During auto-migration, nix-homebrew will delete the existing installation while keeping installed packages."
        exit 1
      fi

      ohai "Attempting to migrate Homebrew installation..."
      ${tools.nuke-homebrew-repository} "$HOMEBREW_REPOSITORY"
    fi

    if [[ ! -e "$HOMEBREW_PREFIX/${nixMarker}" ]]; then
      initialize_prefix
    fi

    # Synthetize $HOMEBREW_LIBRARY
    ln_force "${brew}/Library/Homebrew" "$HOMEBREW_LIBRARY/Homebrew"
    ${setupTaps prefix.taps}

    # Make a fake $HOMEBREW_REPOSITORY
    /bin/rm -rf "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix"
    "''${MKDIR[@]}" "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix/.git"
    "''${CHOWN[@]}" "$NIX_HOMEBREW_UID:$NIX_HOMEBREW_GID" "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix"
    "''${CHMOD[@]}" 775 "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix/"{,.git}
    "''${TOUCH[@]}" "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix/.git/HEAD"

    # Link generated bin/brew
    BIN_BREW="$HOMEBREW_PREFIX/bin/brew"
    if is_occupied "$BIN_BREW"; then
      error "An existing $BIN_BREW is in the way"
      exit 1
    fi
    ln_force "${makeBinBrew prefix}" "$BIN_BREW"
  '';

  setupTaps = taps:
    # Mixed taps
    if cfg.mutableTaps then lib.concatMapStrings (path: let
      # Each path must be in the form of user/repo
      namespace = builtins.head (lib.splitString "/" path);
      target = taps.${path};

      namespaceDir = "$HOMEBREW_LIBRARY/Taps/${namespace}";
      tapDir = "$HOMEBREW_LIBRARY/Taps/${path}";
    in ''
      if [[ -e "${namespaceDir}" ]] && [[ ! -d "${namespaceDir}" ]]; then
        error "$tty_underline${namespaceDir}$tty_reset is in the way and needs to be moved out for $tty_underline${path}$tty_reset"
        exit 1
      fi
      if is_occupied "${tapDir}"; then
        error "An existing $tty_underline${tapDir}$tty_reset is in the way"
        exit 1
      fi
      "''${MKDIR[@]}" "${namespaceDir}"
      "''${CHOWN[@]}" "$NIX_HOMEBREW_UID:$NIX_HOMEBREW_GID" "${namespaceDir}"
      "''${CHMOD[@]}" "ug=rwx" "${namespaceDir}"
      ln_force "${target}" "${tapDir}"
    '') (builtins.attrNames taps)

    # Fully declarative taps
    else let
      env = pkgs.runCommandLocal "taps-env" {} (lib.concatMapStrings (path: let
        namespace = builtins.head (lib.splitString "/" path);
        target = taps.${path};
      in ''
        mkdir -p "$out/${namespace}"
        ln -s "${target}" "$out/${path}"
      '') (builtins.attrNames taps));
    in ''
      if is_occupied "$HOMEBREW_LIBRARY/Taps"; then
        error "An existing $tty_underline$HOMEBREW_LIBRARY/Taps$tty_reset is in the way"
        exit 1
      fi

      ln_force "${env}" "$HOMEBREW_LIBRARY/Taps"
    '';

  enabledPrefixes = lib.filter (prefix: prefix.enable) (builtins.attrValues cfg.prefixes);
in
{
  setupScript = pkgs.writeShellScript "setup-homebrew" ''
    set -euo pipefail
    source ${./utils-common.sh}
    source ${utilsFile}

    NIX_HOMEBREW_UID=$(/usr/bin/id -u "${cfg.user}" || (error "Failed to get UID of ${cfg.user}"; exit 1))
    ${gidScript}

    is_in_nix_store() {
      # /nix/store/anything -> inside
      # /nix/store/.../link-to-outside-store -> inside
      # ./result-link-into-store -> inside

      [[ "$1" != "${builtins.storeDir}"* ]] || return 0

      if [[ -e "$1" ]]
      then
        path=$(/usr/bin/readlink -f $1)
      else
        path="$1"
      fi

      if [[ "$path" == "${builtins.storeDir}"* ]]
      then
        return 0
      else
        return 1
      fi
    }

    is_occupied() {
      [[ -e "$1" ]] && ([[ ! -L "$1" ]] || ! is_in_nix_store "$1")
    }

    ${lnForceFunction}

    ${lib.concatMapStrings setupPrefix enabledPrefixes}

    ${postSetupSnippet}
  '';
}