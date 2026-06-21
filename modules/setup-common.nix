# Shared Homebrew setup script generator
# Platform wrappers pass the small OS-specific differences.

{
  lib,
  pkgs,
  config,
}:
{
  utilsFile,
  commands,
  statArgs,
  permissionFormat,
  installArgs,
  activationMode,
  runAsUser,
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
  isHomeManager = activationMode == "home-manager";

  homeManagerManagedDirectories = [
    "bin"
    "etc"
    "include"
    "lib"
    "sbin"
    "share"
    "opt"
    "var"
    "Frameworks"
    "Cellar"
    "Caskroom"
    "etc/bash_completion.d"
    "lib/pkgconfig"
    "share/aclocal"
    "share/doc"
    "share/info"
    "share/locale"
    "share/man"
    "share/man/man1"
    "share/man/man2"
    "share/man/man3"
    "share/man/man4"
    "share/man/man5"
    "share/man/man6"
    "share/man/man7"
    "share/man/man8"
    "share/zsh"
    "share/zsh/site-functions"
    "var/log"
    "var/homebrew"
    "var/homebrew/linked"
  ];

  checkHomeManagerPrefix = prefix: ''
    HOMEBREW_PREFIX="${prefix.prefix}"
    HOMEBREW_LIBRARY="${prefix.library}"

    if [[ ! -e "$HOMEBREW_PREFIX" ]]; then
      error "Home Manager cannot set up Homebrew because $HOMEBREW_PREFIX does not exist."
      ohai "Create the prefix once before activating again:"
      ohai "  sudo install -d -o ${lib.escapeShellArg cfg.user} -g '$NIX_HOMEBREW_PRIMARY_GROUP' -m 0755 ${lib.escapeShellArg prefix.prefix}"
      exit 1
    fi

    if [[ ! -d "$HOMEBREW_PREFIX" ]]; then
      error "Home Manager cannot set up Homebrew because $HOMEBREW_PREFIX is not a directory."
      exit 1
    fi

    check_home_manager_directory "$HOMEBREW_PREFIX"
    ${lib.concatMapStrings (directory: ''
      check_home_manager_directory "$HOMEBREW_PREFIX/${directory}"
    '') homeManagerManagedDirectories}
    check_home_manager_directory "''${HOMEBREW_LIBRARY%/*}"
    check_home_manager_directory "$HOMEBREW_LIBRARY"

    if [[ -d "$HOMEBREW_LIBRARY" ]] && [[ ! -L "$HOMEBREW_LIBRARY" ]]; then
      while IFS= read -r -d ''' managed_directory; do
        check_home_manager_directory "$managed_directory"
      done < <("''${FIND[@]}" "$HOMEBREW_LIBRARY" -type d -print0)
    fi
  '';

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
    "''${RM[@]}" -rf "$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix"
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

    ${setupTrust}
  '';

  setupTrust =
    let
      trustEntries =
        flag: entries:
        lib.concatMapStrings (entry: ''
          ${runAsUser ''"$BIN_BREW" trust ${flag} ${lib.escapeShellArg entry}''} >/dev/null
        '') entries;
    in
    ''
      ${trustEntries "--tap" cfg.trust.taps}
      ${trustEntries "--formula" cfg.trust.formulae}
      ${trustEntries "--cask" cfg.trust.casks}
      ${trustEntries "--command" cfg.trust.commands}
    '';

  setupTaps =
    taps:
    # Mixed taps
    if cfg.mutableTaps then
      lib.concatMapStrings (
        path:
        let
          # Each path must be in the form of user/repo
          namespace = builtins.head (lib.splitString "/" path);
          target = taps.${path};

          namespaceDir = "$HOMEBREW_LIBRARY/Taps/${namespace}";
          tapDir = "$HOMEBREW_LIBRARY/Taps/${path}";
        in
        ''
          if [[ -e "${namespaceDir}" ]] && [[ ! -d "${namespaceDir}" ]]; then
            error "$tty_underline${namespaceDir}$tty_reset is in the way and needs to be moved out for $tty_underline${path}$tty_reset"
            exit 1
          fi
          if [[ -L "${tapDir}" ]]; then
            "''${RM[@]}" "${tapDir}"
          elif [[ -d "${tapDir}" ]]; then
            :
          elif is_occupied "${tapDir}"; then
            error "An existing $tty_underline${tapDir}$tty_reset is in the way"
            exit 1
          fi
          "''${MKDIR[@]}" "${namespaceDir}"
          "''${CHOWN[@]}" "$NIX_HOMEBREW_UID:$NIX_HOMEBREW_GID" "${namespaceDir}"
          "''${CHMOD[@]}" "ug=rwx" "${namespaceDir}"
          "''${RSYNC[@]}" -rL --delete "${target}/" "${tapDir}"
        ''
      ) (builtins.attrNames taps)

    # Fully declarative taps
    else
      let
        env = pkgs.runCommandLocal "taps-env" { } (
          ''
            mkdir -p "$out"
          ''
          + lib.concatMapStrings (
            path:
            let
              namespace = builtins.head (lib.splitString "/" path);
              target = taps.${path};
            in
            ''
              mkdir -p "$out/${namespace}"
              cp -RH "${target}" "$out/${path}"
            ''
          ) (builtins.attrNames taps)
        );
      in
      ''
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

    ID=(${lib.escapeShellArgs [ commands.id ]})
    FIND=(${lib.escapeShellArgs [ commands.find ]})
    READLINK=(${lib.escapeShellArgs [ commands.readlink ]})
    RM=(${lib.escapeShellArgs [ commands.rm ]})
    LN=(${lib.escapeShellArgs [ commands.ln ]})
    RSYNC=(${lib.escapeShellArgs [ commands.rsync ]})
    STAT_PRINTF=(${lib.escapeShellArgs ([ commands.stat ] ++ statArgs)})
    PERMISSION_FORMAT=${lib.escapeShellArg permissionFormat}
    CHMOD=(${lib.escapeShellArgs [ commands.chmod ]})
    CHOWN=(${lib.escapeShellArgs [ commands.chown ]})
    CHGRP=(${lib.escapeShellArgs [ commands.chgrp ]})
    MKDIR=(${lib.escapeShellArgs [ commands.mkdir ]} -p)
    TOUCH=(${lib.escapeShellArgs [ commands.touch ]})
    INSTALL=(${lib.escapeShellArgs ([ commands.install ] ++ installArgs)})

    ${
      if isHomeManager then
        ''
          NIX_HOMEBREW_UID=$("''${ID[@]}" -u ${lib.escapeShellArg cfg.user} || (error "Failed to get UID of ${cfg.user}"; exit 1))
          CURRENT_UID=$("''${ID[@]}" -u)
          if [[ "$CURRENT_UID" != "$NIX_HOMEBREW_UID" ]]; then
            error "Home Manager activation must run as the configured user ${cfg.user}."
            exit 1
          fi

          NIX_HOMEBREW_GID=$("''${ID[@]}" -g ${lib.escapeShellArg cfg.user} || (error "Failed to get the primary group ID of ${cfg.user}"; exit 1))
          CURRENT_GID=$("''${ID[@]}" -g)
          if [[ "$CURRENT_GID" != "$NIX_HOMEBREW_GID" ]]; then
            error "Home Manager activation must run with the primary group of ${cfg.user}."
            exit 1
          fi

          NIX_HOMEBREW_PRIMARY_GROUP=$("''${ID[@]}" -gn ${lib.escapeShellArg cfg.user} || (error "Failed to get the primary group of ${cfg.user}"; exit 1))
        ''
      else
        ''
          NIX_HOMEBREW_UID=$("''${ID[@]}" -u "${cfg.user}" || (error "Failed to get UID of ${cfg.user}"; exit 1))
          ${gidScript}
        ''
    }

    is_in_nix_store() {
      # /nix/store/anything -> inside
      # /nix/store/.../link-to-outside-store -> inside
      # ./result-link-into-store -> inside

      [[ "$1" != "${builtins.storeDir}"* ]] || return 0

      if [[ -e "$1" ]]
      then
        path=$("''${READLINK[@]}" -f "$1")
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

    ${lib.optionalString isHomeManager ''
      home_manager_bootstrap_required() {
        local path="$1"
        local escaped_path
        printf -v escaped_path '%q' "$path"

        error "Home Manager cannot set up Homebrew because $path is not writable."
        ohai "Prepare the managed path once before activating again:"
        ohai "  sudo chown -R ${lib.escapeShellArg cfg.user}:'$NIX_HOMEBREW_PRIMARY_GROUP' $escaped_path"
        ohai "  sudo chmod -R u+rwX $escaped_path"
        exit 1
      }

      check_home_manager_directory() {
        local path="$1"

        if [[ -e "$path" ]] || [[ -L "$path" ]]; then
          if [[ ! -d "$path" ]]; then
            error "Home Manager cannot set up Homebrew because $path is not a directory."
            exit 1
          fi

          if [[ ! -w "$path" ]] || [[ ! -x "$path" ]]; then
            home_manager_bootstrap_required "$path"
          fi
        fi
      }
    ''}

    ${lnForceFunction}

    ${lib.optionalString isHomeManager (lib.concatMapStrings checkHomeManagerPrefix enabledPrefixes)}

    ${lib.concatMapStrings setupPrefix enabledPrefixes}

    ${postSetupSnippet}
  '';
}
