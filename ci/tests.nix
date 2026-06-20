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

  disabledSystemModule =
    { config, pkgs, ... }:
    let
      systemPackages = config.environment.systemPackages;
      activationScripts = config.system.activationScripts;
      systemPackageNames = map lib.getName systemPackages;
      activationScriptNames = builtins.attrNames activationScripts;
    in
    {
      nix-homebrew.enable = false;
      system.stateVersion = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.mkForce "26.05");

      ci.script =
        assert !(builtins.elem "brew" systemPackageNames);
        assert !(activationScripts ? setup-homebrew);
        builtins.deepSeq systemPackageNames (
          builtins.deepSeq activationScriptNames ''
            ${pkgs.coreutils}/bin/true
          ''
        );
    };

  disabledHomeManager =
    let
      hmLib = lib // {
        hm.dag.entryAfter = _: value: value;
      };
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          (self + "/modules/common.nix")
          (
            { lib, ... }:
            {
              options = {
                assertions = lib.mkOption {
                  type = lib.types.listOf (
                    lib.types.submodule {
                      options = {
                        assertion = lib.mkOption { type = lib.types.bool; };
                        message = lib.mkOption { type = lib.types.str; };
                      };
                    }
                  );
                  default = [ ];
                };
                home = {
                  username = lib.mkOption {
                    type = lib.types.str;
                    default = "runner";
                  };
                  packages = lib.mkOption {
                    type = lib.types.listOf lib.types.package;
                    default = [ ];
                  };
                  activation = lib.mkOption {
                    type = lib.types.attrsOf lib.types.lines;
                    default = { };
                  };
                };
                programs = {
                  bash.initExtra = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                  zsh.initContent = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                  fish.interactiveShellInit = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                };
                system.build.ci-script = lib.mkOption {
                  type = lib.types.package;
                };
              };
            }
          )
          (
            args@{ config, options, ... }:
            import (self + "/modules/home-manager.nix") (
              args
              // {
                lib = hmLib;
                inherit config options;
              }
            )
          )
          (
            { config, pkgs, ... }:
            let
              homePackages = config.home.packages;
              homeActivation = config.home.activation;
            in
            {
              nix-homebrew.enable = false;

              system.build.ci-script =
                assert homePackages == [ ];
                assert !(homeActivation ? setup-homebrew);
                builtins.deepSeq homePackages (
                  builtins.deepSeq homeActivation (
                    pkgs.writeShellScript "disabled-home-manager" ''
                      ${pkgs.coreutils}/bin/true
                    ''
                  )
                );
            }
          )
        ];
      };
    in
    evaluated;

  launcherContentModule =
    { config, pkgs, ... }:
    let
      cfg = config.nix-homebrew;
      prefixName =
        if pkgs.stdenv.hostPlatform.isLinux then
          cfg.defaultLinuxPrefix
        else if pkgs.stdenv.hostPlatform.isAarch64 then
          cfg.defaultArm64Prefix
        else
          cfg.defaultIntelPrefix;
      prefixLauncher = cfg.makeBinBrew cfg.prefixes.${prefixName};
      expectedShebang =
        if pkgs.stdenv.hostPlatform.isDarwin then "#!/bin/bash" else "#!${pkgs.bash}/bin/bash";
      launcherContent = pkgs.runCommandLocal "launcher-content" { } ''
        failed=0

        check_shebang() {
          launcher_name="$1"
          launcher_path="$2"
          actual_shebang="$(${pkgs.coreutils}/bin/head -n 1 "$launcher_path")"

          if [[ "$actual_shebang" != ${lib.escapeShellArg expectedShebang} ]]; then
            >&2 echo "$launcher_name launcher starts with $actual_shebang"
            >&2 echo "expected ${expectedShebang}"
            failed=1
          fi
        }

        check_shebang unified "${cfg.brewLauncher}/bin/brew"
        check_shebang prefix "${prefixLauncher}"

        (( failed == 0 ))
        touch "$out"
      '';
    in
    {
      nix-homebrew.enable = true;
      system.stateVersion = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.mkForce "26.05");

      ci.script = lib.mkForce ''
        cat "${launcherContent}"
      '';
    };

  makeTapValidationTest =
    {
      mutableTaps ? true,
    }:
    makeTest {
      darwinModule =
        { pkgs, config, ... }:
        let
          prefixName =
            if pkgs.stdenv.hostPlatform.isAarch64 then
              config.nix-homebrew.defaultArm64Prefix
            else
              config.nix-homebrew.defaultIntelPrefix;
          library = config.nix-homebrew.prefixes.${prefixName}.library;
          fakeCaskTap = pkgs.runCommandLocal "homebrew-cask-test-tap" { } ''
            mkdir -p "$out/Casks/u"
            touch "$out/Casks/u/ungoogled-chromium.rb"
          '';
          fakeThirdPartyTap = pkgs.runCommandLocal "thirdparty-test-tap" { } ''
            mkdir -p "$out/Formula" "$out/Casks" "$out/cmd"
            touch "$out/Formula/foo.rb"
            touch "$out/Casks/test-cask.rb"
            touch "$out/cmd/brew-test-command.rb"
          '';
        in
        {
          nix-homebrew = {
            enable = true;
            autoMigrate = true;
            inherit mutableTaps;
            taps = {
              "homebrew/homebrew-cask" = fakeCaskTap;
              "thirdparty/homebrew-testtap" = fakeThirdPartyTap;
            };
            trust = {
              formulae = [ "thirdparty/testtap/foo" ];
              casks = [ "thirdparty/testtap/test-cask" ];
              commands = [ "thirdparty/testtap/test-command" ];
            };
          };

          ci.preScript = ''
            >&2 echo "Removing runner Homebrew taps before declarative tap validation"
            if [[ -e "${library}/Taps" || -L "${library}/Taps" ]]; then
              sudo rm -rf "${library}/Taps"
            fi
          '';

          ci.postScript = ''
            >&2 echo "Checking declarative cask tap realpaths"
            tap_root="${library}/Taps"
            cask_path="$tap_root/homebrew/homebrew-cask/Casks/u/ungoogled-chromium.rb"

            test -f "$cask_path"

            >&2 echo "Checking declarative Homebrew trust entries"
            brew trust --json=v1 --formula | grep '"thirdparty/testtap/foo"'
            brew trust --json=v1 --cask | grep '"thirdparty/testtap/test-cask"'
            brew trust --json=v1 --command | grep '"thirdparty/testtap/test-command"'
            if brew trust --json=v1 --tap | grep '"thirdparty/testtap"'; then
              >&2 echo "Expected thirdparty/testtap not to be trusted as a whole tap"
              exit 1
            fi

            tap_root_real="$(${pkgs.coreutils}/bin/realpath "$tap_root")"
            cask_real="$(${pkgs.coreutils}/bin/realpath "$cask_path")"

            case "$cask_real" in
              "$tap_root_real"/*) ;;
              *)
                >&2 echo "Expected cask realpath to stay under managed Taps root"
                >&2 echo "Taps realpath: $tap_root_real"
                >&2 echo "Cask realpath: $cask_real"
                exit 1
                ;;
            esac
          '';
        };
    };
in
{
  disabled-system = makeTest {
    darwinModule = disabledSystemModule;
    linuxModule = disabledSystemModule;
  };

  disabled-home-manager = disabledHomeManager;

  launcher-content = makeTest {
    darwinModule = launcherContentModule;
    linuxModule = launcherContentModule;
  };

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

  tap-validation-mutable = makeTapValidationTest { };

  tap-validation-declarative = makeTapValidationTest {
    mutableTaps = false;
  };

  nuke-homebrew-repository = makeTest {
    darwinModule = nukeModule;
    linuxModule = nukeModule;
  };
}
