# Darwin-specific wrapper around the shared setup generator.

{ lib, pkgs, config }:
(import ./setup-common.nix { inherit lib pkgs config; }) {
  utilsFile = ./utils-darwin.sh;
  gidScript = ''
    NIX_HOMEBREW_GID=$(/usr/bin/dscl . -read "/Groups/${config.nix-homebrew.group}" | /usr/bin/awk '($1 == "PrimaryGroupID:") { print $2 }' || (error "Failed to get GID of ${config.nix-homebrew.group}"; exit 1))
  '';
  lnForceFunction = ''
    ln_force() {
      /bin/ln -shf "$1" "$2"
    }
  '';
  detectRepositorySnippet = ''
    if [[ -e "$HOMEBREW_PREFIX/.git" ]]; then
      # Looks like an Apple Silicon installation
      ohai "Looks like an Apple Silicon installation (Homebrew prefix is the repository)"
      HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX"
    elif [[ -e "$HOMEBREW_PREFIX/Homebrew/.git" ]]; then
      # Looks like an Intel installation
      ohai "Looks like an Intel installation (Homebrew repository is under the 'Homebrew' subdirectory)"
      HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"
    else
      # Custom installation?
      ohai "Please uninstall Homebrew and try activating again."
      exit 1
    fi
  '';
  postSetupSnippet = ''
    if test -n "${toString config.nix-homebrew.enableRosetta}" && ! /usr/bin/pgrep -q oahd; then
      warn "The Intel Homebrew prefix has been set up, but Rosetta isn't installed yet."
      ohai "Run ''${tty_bold}softwareupdate --install-rosetta''${tty_reset} to install it."
    fi
  '';
}
