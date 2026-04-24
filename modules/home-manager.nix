# Home Manager specific configuration for nix-homebrew
# Handles Home Manager integration

{ pkgs, lib, config, options, ... }:
let
  cfg = config.nix-homebrew;
in
lib.mkIf (options ? home) {
  # Platform-specific prefix defaults for Home Manager
  # (linux.nix and darwin.nix are not imported in the homeManagerModules path)
  nix-homebrew.prefixes = lib.mkMerge [
    (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      "/home/linuxbrew/.linuxbrew" = {
        enable = true;
        library = "/home/linuxbrew/.linuxbrew/Homebrew/Library";
        taps = cfg.taps;
      };
    })
    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
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
    })
  ];

  nix-homebrew.group = lib.mkDefault (
    if pkgs.stdenv.hostPlatform.isDarwin then "admin"
    else "users"
  );

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
