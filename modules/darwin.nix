# Darwin (macOS) specific configuration for nix-homebrew
# Handles nix-darwin integration and Darwin-specific setup

{ pkgs, lib, config, options, ... }:
let
  cfg = config.nix-homebrew;

  # Import shared Nix setup logic
  darwinSetupNix = import ./setup-darwin.nix { inherit lib pkgs config; };
in
{
  assertions = [
    {
      assertion = cfg.enableRosetta -> pkgs.stdenv.hostPlatform.isAarch64;
      message = "nix-homebrew.enableRosetta is set to true but this isn't an Apple Silicon Mac";
    }
    {
      # nix-darwin has migrated away from user activation in
      # <https://github.com/LnL7/nix-darwin/pull/1341>.
      assertion = (options ? home) || options.system ? primaryUser;
      message = "Please update your nix-darwin version to use system-wide activation";
    }
  ];

  # Darwin defaults
  nix-homebrew.group = lib.mkDefault "admin";

  nix-homebrew.prefixes = {
    "/opt/homebrew" = {
      enable = pkgs.stdenv.hostPlatform.isAarch64;
      library = "/opt/homebrew/Library";
      taps = cfg.taps;
    };
    "/usr/local" = {
      enable = pkgs.stdenv.hostPlatform.isx86_64 || cfg.enableRosetta;
      library = "/usr/local/Homebrew/Library";
      taps = cfg.taps;
    };
  };

  # System-level package management
  environment.systemPackages = [ cfg.brewLauncher ];

  # Shell integrations for Darwin
  programs.bash.interactiveShellInit = lib.mkIf cfg.enableBashIntegration ''
    eval "$(brew shellenv 2>/dev/null || true)"
  '';

  programs.zsh.interactiveShellInit = lib.mkIf cfg.enableZshIntegration ''
    eval "$(brew shellenv 2>/dev/null || true)"
  '';

  programs.fish.interactiveShellInit = lib.mkIf cfg.enableFishIntegration ''
    brew shellenv 2>/dev/null | source || true
  '';

  # System-level activation
  system.activationScripts = {
    # Set up the Homebrew prefixes before nix-darwin's homebrew
    # activation takes place.
    homebrew.text = lib.mkIf (options ? homebrew) (lib.mkBefore ''
      ${config.system.activationScripts.setup-homebrew.text}
    '');
    setup-homebrew.text = darwinSetupNix.setupScript;
  };

  # disable the install homebrew check
  # see https://github.com/LnL7/nix-darwin/pull/1178 and https://github.com/zhaofengli/nix-homebrew/issues/45
  system.checks.text = lib.mkIf ((options ? homebrew) && config.homebrew.enable) (lib.mkBefore ''
    # Ignore unused variable in nix-darwin versions without it
    # shellcheck disable=SC2034
    INSTALLING_HOMEBREW=1
  '');
}
