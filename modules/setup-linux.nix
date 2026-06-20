# Linux-specific wrapper around the shared setup generator.

{
  lib,
  pkgs,
  config,
}:
(import ./setup-common.nix { inherit lib pkgs config; }) {
  utilsFile = ./utils-linux.sh;
  commands = {
    id = "${pkgs.coreutils}/bin/id";
    readlink = "${pkgs.coreutils}/bin/readlink";
    rm = "${pkgs.coreutils}/bin/rm";
    ln = "${pkgs.coreutils}/bin/ln";
    rsync = "${pkgs.rsync}/bin/rsync";
    stat = "${pkgs.coreutils}/bin/stat";
    chmod = "${pkgs.coreutils}/bin/chmod";
    chown = "${pkgs.coreutils}/bin/chown";
    chgrp = "${pkgs.coreutils}/bin/chgrp";
    mkdir = "${pkgs.coreutils}/bin/mkdir";
    touch = "${pkgs.coreutils}/bin/touch";
    install = "${pkgs.coreutils}/bin/install";
  };
  statArgs = [ "--printf" ];
  permissionFormat = "%a";
  installArgs = [
    "-d"
    "-o"
    "root"
    "-g"
    "root"
    "-m"
    "0755"
  ];
  runAsUser =
    command:
    "${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg config.nix-homebrew.user} -- ${command}";
  gidScript = ''
    NIX_HOMEBREW_GID=$("''${ID[@]}" -g "${config.nix-homebrew.user}" || (error "Failed to get a group ID for ${config.nix-homebrew.user}"; exit 1))
  '';
  lnForceFunction = ''
    ln_force() {
      "''${LN[@]}" -sfn "$1" "$2"
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
