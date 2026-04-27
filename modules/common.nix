# Common nix-homebrew configuration shared across all platforms
# Platform-specific overrides are handled by darwin.nix and linux.nix

{ pkgs, lib, config, options, ... }:
let
  inherit (lib) types;

  # When this file exists under $HOMEBREW_PREFIX or a specific
  # tap, it means it's managed by us.
  nixMarker = ".managed_by_nix_darwin";

  cfg = config.nix-homebrew;

  tools = pkgs.callPackage ../pkgs { };

  brew = if cfg.patchBrew then patchBrew cfg.package else cfg.package;
  ruby = pkgs.ruby_4_0;

  # Sadly, we cannot replace coreutils since the GNU implementations
  # behave differently.
  runtimePath = lib.makeBinPath [ pkgs.gitMinimal ]
    + lib.optionalString pkgs.stdenv.hostPlatform.isLinux ":/run/current-system/sw/bin";

  prefixType = types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        description = ''
          Whether to set up this Homebrew prefix.
        '';
      };
      prefix = lib.mkOption {
        description = ''
          The Homebrew prefix.

          By default, it's `/opt/homebrew` for Apple Silicon Macs and
          `/usr/local` for Intel Macs.
        '';
        type = types.str;
        default = name;
      };
      library = lib.mkOption {
        description = ''
          The Homebrew library.

          By default, it's `/opt/homebrew/Library` for Apple Silicon Macs and
          `/usr/local/Homebrew/Library` for Intel Macs.
        '';
        type = types.str;
      };
      taps = lib.mkOption {
        description = ''
          A set of Nix-managed taps.
        '';
        type = types.attrsOf types.package;
        default = {};
        example = lib.literalExpression ''
          {
            "homebrew/homebrew-core" = pkgs.fetchFromGitHub {
              owner = "homebrew";
              repo = "homebrew-core";
              rev = "...";
              hash = "...";
            };
          }
        '';
      };
    };
  });

  # Our unified brew launcher script.
  #
  # We use `/bin/bash` (Bash 3.2 :/) instead of `${runtimeShell}`
  # for compatibility with `arch -x86_64`.
  brewLauncher = pkgs.writeScriptBin "brew" (''
    #!/bin/bash
    set -euo pipefail
    cur_os=$(uname -s)
    cur_arch=$(uname -m)
  '' + lib.optionalString (cfg.prefixes ? ${cfg.defaultLinuxPrefix} && cfg.prefixes.${cfg.defaultLinuxPrefix}.enable) ''
    if [[ "$cur_os" == "Linux" ]]; then
      exec "${cfg.prefixes.${cfg.defaultLinuxPrefix}.prefix}/bin/brew" "$@"
    fi
  '' + lib.optionalString (cfg.prefixes ? ${cfg.defaultArm64Prefix} && cfg.prefixes.${cfg.defaultArm64Prefix}.enable) ''
    if [[ "$cur_os" == "Darwin" ]] && [[ "$cur_arch" == "arm64" ]]; then
      exec "${cfg.prefixes.${cfg.defaultArm64Prefix}.prefix}/bin/brew" "$@"
    fi
  '' + lib.optionalString (cfg.prefixes ? ${cfg.defaultIntelPrefix} && cfg.prefixes.${cfg.defaultIntelPrefix}.enable) ''
    if [[ "$cur_os" == "Darwin" ]] && [[ "$cur_arch" == "x86_64" ]]; then
      exec "${cfg.prefixes.${cfg.defaultIntelPrefix}.prefix}/bin/brew" "$@"
    fi
  '' + ''
    >&2 echo "nix-homebrew: No Homebrew installation available for $cur_os/$cur_arch"
    exit 1
  '');

  # Prefix-specific bin/brew
  #
  # No prefix/library/repo auto-detection, everything is configured by Nix.
  makeBinBrew = prefix: let
    template = pkgs.writeText "brew.in" (''
      #!/bin/bash
      export HOMEBREW_PREFIX="@prefix@"
      export HOMEBREW_LIBRARY="@library@"
      export HOMEBREW_REPOSITORY="$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix"
      export HOMEBREW_BREW_FILE="@out@"

      # Homebrew itself cannot self-update, so we set
      # fake before/after versions to make `update-report.rb` happy
      export HOMEBREW_UPDATE_BEFORE="nix"
      export HOMEBREW_UPDATE_AFTER="nix"
    '' + lib.optionalString (!cfg.mutableTaps) ''
      # Disable auto-update since everything is pinned
      export HOMEBREW_NO_AUTO_UPDATE=1
    '' + lib.optionalString (prefix.taps ? "homebrew/homebrew-core") ''
      # Disable API to use pinned homebrew-core
      export HOMEBREW_NO_INSTALL_FROM_API=1
    '' + (lib.optionalString (cfg.extraEnv != {})
            (lib.concatLines (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.extraEnv)))
       + (builtins.readFile ./brew.tail.sh));
  in pkgs.replaceVarsWith {
    name = "brew";
    src = template;
    isExecutable = true;

    # Must retain #!/bin/bash, otherwise `arch -x86_64 /usr/local/bin/brew`
    # on Apple Silicon will not work.
    dontPatchShebangs = true;

    replacements = {
      out = placeholder "out";
      inherit runtimePath;
      inherit (prefix) prefix library;
    };
  };

  patchBrew = brew: pkgs.runCommandLocal "${brew.name or "brew"}-patched" {} (''
    cp -r "${brew}" "$out"
    chmod u+w "$out" "$out/Library/Homebrew/cmd"

    # Disable self-update behavior
    substituteInPlace "$out/Library/Homebrew/cmd/update.sh" \
      --replace-fail 'for DIR in "''${HOMEBREW_REPOSITORY}"' "for DIR in "

    # Homebrew passes --disable=gems,rubyopt ($HOMEBREW_RUBY_DISABLE_OPTIONS)
    # and inserts vendored libraries into LOAD_PATH (vendor/bundle/bundler/setup.rb, standalone/init.rb).
    # Instead of re-enabling gems, we add in additional required gems into LOAD_PATH.
    ruby_sh="$out/Library/Homebrew/utils/ruby.sh"
    bundler_setup_rb="$out/Library/Homebrew/vendor/bundle/bundler/setup.rb"
    if [[ -e "$ruby_sh" ]] && grep "setup-ruby-path" "$ruby_sh" >/dev/null; then
      >&2 echo "Patching vendored Ruby..."
      chmod u+w "$ruby_sh" "$bundler_setup_rb"
      echo -e "setup-ruby-path() { export HOMEBREW_RUBY_PATH=\"${ruby}/bin/ruby\"; }" >>"$ruby_sh"
      echo -e "$:.unshift \"${ruby.gems.fiddle}/${ruby.gemPath}/gems/fiddle-${ruby.gems.fiddle.version}/lib\"" >>"$bundler_setup_rb"
    fi
  '' + lib.optionalString (brew ? version) ''
    # Embed version number instead of checking with git
    brew_sh="$out/Library/Homebrew/brew.sh"
    chmod u+w "$out/Library/Homebrew" "$brew_sh"
    sed -i -e 's/^HOMEBREW_VERSION=.*/HOMEBREW_VERSION="${brew.version}"/g' "$brew_sh"

    # 4.3.5: Clear GIT_REVISION to bypass caching mechanism
    sed -i -e 's/^GIT_REVISION=.*/GIT_REVISION=""; HOMEBREW_VERSION="${brew.version}"/g' "$brew_sh"
  '');

in {
  options = {
    nix-homebrew = {
      enable = lib.mkOption {
        description = ''
          Whether to install Homebrew.
        '';
        type = types.bool;
        default = false;
      };
      enableRosetta = lib.mkOption {
        description = ''
          Whether to set up the Homebrew prefix for Rosetta 2.

          This is only supported on Apple Silicon Macs.
        '';
        type = types.bool;
        default = false;
      };
      package = lib.mkOption {
        description = ''
          The homebrew package itself.
        '';
        type = types.package;
      };
      taps = lib.mkOption {
        description = ''
          A set of Nix-managed taps.

          These are applied to the default prefixes.
        '';
        type = types.attrsOf types.package;
        default = {};
        example = lib.literalExpression ''
          {
            "homebrew/homebrew-core" = pkgs.fetchFromGitHub {
              owner = "homebrew";
              repo = "homebrew-core";
              rev = "...";
              hash = "...";
            };
          }
        '';
      };
      mutableTaps = lib.mkOption {
        description = ''
          Whether to allow imperative management of taps.

          When enabled, taps can be managed via `brew tap` and
          `brew update`.

          When disabled, the auto-update functionality is also
          automatically disabled with `HOMEBREW_NO_AUTO_UPDATE=1`.
        '';
        type = types.bool;
        default = true;
      };
      autoMigrate = lib.mkOption {
        description = ''
          Whether to allow nix-homebrew to automatically migrate existing Homebrew installations.

          When enabled, the activation script will automatically delete
          Homebrew repositories while keeping installed packages.
        '';
        type = types.bool;
        default = false;
      };
      user = lib.mkOption {
        description = ''
          The user owning the Homebrew directories.
        '';
        type = types.str;
      };
      group = lib.mkOption {
        description = ''
          The group owning the Homebrew directories.
        '';
        type = types.str;
        default = "wheel"; # Platform-specific modules can override this
      };

      # Advanced options

      prefixes = lib.mkOption {
        description = ''
          A set of Homebrew prefixes to set up.

          Usually you don't need to configure this and sensible
          defaults are already set up.
        '';
        type = types.attrsOf prefixType;
      };
      defaultArm64Prefix = lib.mkOption {
        description = ''
          Key of the default Homebrew prefix for ARM64 macOS.
        '';
        internal = true;
        type = types.str;
        default = "/opt/homebrew";
      };
      defaultIntelPrefix = lib.mkOption {
        description = ''
          Key of the default Homebrew prefix for Intel macOS or Rosetta 2.
        '';
        internal = true;
        type = types.str;
        default = "/usr/local";
      };
      defaultLinuxPrefix = lib.mkOption {
        description = ''
          Key of the default Homebrew prefix for Linux.
        '';
        internal = true;
        type = types.str;
        default = "/home/linuxbrew/.linuxbrew";
      };
      extraEnv = lib.mkOption {
        description = ''
          Extra environment variables to set for Homebrew.
        '';
        type = types.attrsOf types.str;
        default = {};
        example = lib.literalExpression ''
          {
            HOMEBREW_NO_ANALYTICS = "1";
          }
        '';
      };
      patchBrew = lib.mkOption {
        description = ''
          Whether to attempt to patch Homebrew to suppress self-updating.
        '';
        type = types.bool;
        default = true;
      };

      # Shell integrations
      enableBashIntegration = lib.mkEnableOption "homebrew bash integration" // {
        default = true;
      };

      enableFishIntegration = lib.mkEnableOption "homebrew fish integration" // {
        default = true;
      };

      enableZshIntegration = lib.mkEnableOption "homebrew zsh integration" // {
        default = true;
      };

      # Internal options for passing values to platform-specific modules
      _brewPackage = lib.mkOption {
        description = "The patched Homebrew package.";
        internal = true;
        type = types.package;
      };
      _nixMarker = lib.mkOption {
        description = "The Nix marker file name.";
        internal = true;
        type = types.str;
      };
      _tools = lib.mkOption {
        description = "The nix-homebrew tools package set.";
        internal = true;
        type = types.attrs;
      };
      brewLauncher = lib.mkOption {
        description = "The unified brew launcher script.";
        internal = true;
        type = types.package;
      };
      makeBinBrew = lib.mkOption {
        description = "Function to create prefix-specific bin/brew.";
        internal = true;
        type = types.functionTo types.package;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != null && cfg.user != "";
        message = "nix-homebrew.user must be set";
      }
    ];

    # Set user default for home-manager
    nix-homebrew.user = lib.mkDefault (if (options ? home) then config.home.username else "");

    nix-homebrew = {
      inherit brewLauncher makeBinBrew;
      _brewPackage = brew;
      _nixMarker = nixMarker;
      _tools = tools;
    };
  };
}
