# Linux (NixOS) specific configuration for nix-homebrew
# Handles NixOS integration and Linux-specific setup

{ pkgs, lib, config, options, ... }:
let
  cfg = config.nix-homebrew;

  # Import shared Linux setup logic
  linuxSetupNix = import ./setup-linux.nix { inherit lib pkgs config; };
in
{
  # Linux defaults
  nix-homebrew.group = lib.mkDefault "users";

  nix-homebrew.prefixes = {
    "/home/linuxbrew/.linuxbrew" = {
      enable = true;
      library = "/home/linuxbrew/.linuxbrew/Homebrew/Library";
      taps = cfg.taps;
    };
  };

  # System-level package management
  environment.systemPackages = [ cfg.brewLauncher ];

  # Shell integrations for Linux
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
    setup-homebrew.text = linuxSetupNix.setupScript;
  };
}
