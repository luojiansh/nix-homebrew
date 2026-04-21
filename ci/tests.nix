{
  self,
  pkgs,
  nix-darwin,
  nixpkgs ? null,
}:

let
  inherit (pkgs) lib system;

  tools = self.packages.${pkgs.system};

  makeSystemTest =
    mkSystem: baseModule: module:
    mkSystem {
      inherit system pkgs;
      modules = [
        baseModule
        module
        (
          {
            pkgs,
            lib,
            config,
            ...
          }:
          {
            options = {
              ci = {
                preScript = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                };
                script = lib.mkOption {
                  type = lib.types.lines;
                  default = ''
                    sudo rm -f /etc/bashrc /etc/nix/nix.conf /etc/nix/nix.custom.conf
                    sudo "${config.system.build.toplevel}/activate"
                    export PATH=/run/current-system/sw/bin:$PATH
                  '';
                };
                postScript = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                };
              };
            };
            config = {
              documentation.enable = false;
              system.stateVersion = 6;
              nix-homebrew = {
                user = lib.mkForce "runner";
              };

              system.build.ci-script = pkgs.writeShellScript "ci-script.sh" ''
                      set -euo pipefail
                      if [[ -z "''${NIX_HOMEBREW_CI:-}" ]]; then
                        >&2 echo "This script can only be run on nix-homebrew CI."
                        exit 1
                      fi
                      set -x
                ${config.ci.preScript}
                ${config.ci.script}
                ${config.ci.postScript}
              '';
            };
          }
        )
      ];
    };

  nukeModule = {
    ci.script = lib.mkForce ''
      cat "${tools.nuke-homebrew-repository.passthru.tests.test-nuke}"
    '';
  };

  makeTest =
    {
      darwinModule ? null,
      linuxModule ? null,
    }:
    if pkgs.stdenv.hostPlatform.isDarwin then
      if darwinModule == null then
        throw "darwinModule must be set for Darwin tests"
      else
        lib.pipe makeSystemTest [
          (applyMkSystem: applyMkSystem nix-darwin.lib.darwinSystem)
          (applyBaseModule: applyBaseModule self.darwinModules.nix-homebrew)
          (applyModule: applyModule darwinModule)
        ]
    else if pkgs.stdenv.hostPlatform.isLinux then
      if linuxModule == null then
        throw "linuxModule must be set for Linux tests"
      else
        lib.pipe makeSystemTest [
          (applyMkSystem: applyMkSystem nixpkgs.lib.nixosSystem)
          (applyBaseModule: applyBaseModule self.nixosModules.nix-homebrew)
          (applyModule: applyModule linuxModule)
        ]
    else
      throw "Unsupported CI test platform: ${pkgs.stdenv.hostPlatform.system}";
in
{
  migrate = makeTest {
    darwinModule =
      { pkgs, config, ... }:
      {
        imports = [
          (self + "/examples/migrate.nix")
        ];
        nix-homebrew.enableRosetta = lib.mkForce pkgs.stdenv.hostPlatform.isAarch64;

        # We only have Apple Silicon instances - Only test the install steps on native
        # Apple Silicon for now
        ci.preScript = lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 ''
          >&2 echo "Installing some package with Homebrew"
          brew install unbound

          >&2 echo "Adding a third-party tap imperatively"
          brew tap koekeishiya/formulae
        '';
        ci.postScript = ''
          >&2 echo "Checking brew"
          which brew
        ''
        + lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 ''
          >&2 echo "Checking that we can still use the unbound package"
          $(brew --prefix)/sbin/unbound -V

          >&2 echo "Checking that we can still use the tap we added imperatively"
          brew install koekeishiya/formulae/yabai
        ''
        + lib.optionalString config.nix-homebrew.enableRosetta ''
          >&2 echo "Checking we can execute the Intel brew with arch -x86_64"
          arch -x86_64 /usr/local/bin/brew config | grep "HOMEBREW_PREFIX: /usr/local"

          >&2 echo "Checking that the unified brew launcher selects the correct prefix"
          arch -arm64 brew config | grep "HOMEBREW_PREFIX: /opt/homebrew"
          arch -x86_64 brew config | grep "HOMEBREW_PREFIX: /usr/local"
        '';
      };
  };

  nuke-homebrew-repository = makeTest {
    darwinModule = nukeModule;
    linuxModule = nukeModule;
  };
}
