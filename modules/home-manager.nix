# Home Manager specific configuration for nix-homebrew
# Handles Home Manager integration

{ pkgs, lib, config, options, ... }:
let
  cfg = config.nix-homebrew;
in
lib.mkIf (options ? home) {
  # Home Manager package management
  home.packages = [ cfg.brewLauncher ];

  # Shell integrations for Home Manager
  programs.bash.initExtra = lib.mkIf cfg.enableBashIntegration ''
    eval "$(brew shellenv 2>/dev/null || true)"
  '';

  programs.zsh.initExtra = lib.mkIf cfg.enableZshIntegration ''
    eval "$(brew shellenv 2>/dev/null || true)"
  '';

  programs.fish.interactiveShellInit = lib.mkIf cfg.enableFishIntegration ''
    brew shellenv 2>/dev/null | source || true
  '';

  # Home Manager activation
  # We need to handle both Darwin and Linux within Home Manager context
  home.activation.setup-homebrew = lib.hm.dag.entryAfter ["writeBoundary"] ''
    run ${
      if pkgs.stdenv.hostPlatform.isDarwin then
        (import ./setup-darwin.nix { inherit lib pkgs config; }).setupScript
      else if pkgs.stdenv.hostPlatform.isLinux then
        (import ./setup-linux.nix { inherit lib pkgs config; }).setupScript
      else
        throw "nix-homebrew: Unsupported platform"
    }
  '';
}
