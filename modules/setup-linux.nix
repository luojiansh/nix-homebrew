# Linux-specific wrapper around the shared setup generator.

{ lib, pkgs, config }:
(import ./setup-common.nix { inherit lib pkgs config; }) {
  utilsFile = ./utils-linux.sh;
  gidScript = ''
    NIX_HOMEBREW_GID=$(/usr/bin/id -g "${config.nix-homebrew.user}" || (error "Failed to get a group ID for ${config.nix-homebrew.user}"; exit 1))
  '';
  lnForceFunction = ''
    ln_force() {
      /bin/ln -sfn "$1" "$2"
    }
  '';
  detectRepositorySnippet = ''
    if [[ -e "$HOMEBREW_PREFIX/.git" ]]; then
      # Looks like a standard Linux installation
      ohai "Looks like a Linux Homebrew installation (Homebrew prefix is the repository)"
      HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX"
    else
      # Custom installation?
      ohai "Please uninstall Homebrew and try activating again."
      exit 1
    fi
  '';
}
