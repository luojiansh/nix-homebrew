{
  self,
  pkgs,
  nix-darwin,
  nixpkgs ? null,
  home-manager ? null,
  home-manager-pkgs ? null,
  linuxStateVersion ? null,
}:

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  tools = self.packages.${system};

  makeCiScript =
    {
      name,
      preScript ? "",
      script ? "",
      requiredPaths ? [ ],
      postScript ? "",
    }:
    pkgs.runCommandLocal name { } ''
      set -euo pipefail
      ${lib.concatMapStringsSep "\n" (path: "test -e ${path}") requiredPaths}

      cat >"$out" <<'EOF'
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      if [[ -z "''${NIX_HOMEBREW_CI:-}" ]]; then
        >&2 echo "This script can only be run on nix-homebrew CI."
        exit 1
      fi
      set -x
      ${preScript}
      ${script}
      ${postScript}
      EOF

      chmod +x "$out"
    '';

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
                requiredPaths = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ ];
                };
                postScript = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                };
              };
            };
            config = {
              documentation.enable = false;
              nix-homebrew = {
                user = lib.mkForce "runner";
              };

              system.build.ci-script = makeCiScript {
                name = "ci-script.sh";
                inherit (config.ci)
                  preScript
                  script
                  requiredPaths
                  postScript
                  ;
              };
            };
          }
        )
      ];
    };

  darwinStateVersionModule = {
    system.stateVersion = 6;
  };

  linuxStateVersionModule =
    if linuxStateVersion == null then
      throw "linuxStateVersion must be set for Linux tests"
    else
      {
        system.stateVersion = linuxStateVersion;
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
          (
            applyModule:
            applyModule {
              imports = [
                darwinStateVersionModule
                darwinModule
              ];
            }
          )
        ]
    else if pkgs.stdenv.hostPlatform.isLinux then
      if linuxModule == null then
        throw "linuxModule must be set for Linux tests"
      else
        lib.pipe makeSystemTest [
          (applyMkSystem: applyMkSystem nixpkgs.lib.nixosSystem)
          (applyBaseModule: applyBaseModule self.nixosModules.nix-homebrew)
          (
            applyModule:
            applyModule {
              imports = [
                linuxStateVersionModule
                linuxModule
              ];
            }
          )
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

  evalHomeManager =
    testModule:
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
          ({ config, pkgs, ... }: testModule { inherit config pkgs; })
        ];
      };
    in
    evaluated;

  disabledHomeManager = evalHomeManager (
    { config, pkgs }:
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
  );

  makeFakeBrewPackage =
    name:
    pkgs.runCommandLocal "${name}-fake-brew" { } ''
      mkdir -p "$out/Library/Homebrew"
      cat >"$out/Library/Homebrew/brew.sh" <<'EOF'
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      case "''${1:-}" in
        config)
          printf 'HOMEBREW_PREFIX: %s\n' "$HOMEBREW_PREFIX"
          ;;
        *)
          printf 'fake brew invoked: %s\n' "$*"
          ;;
      esac
      EOF
      chmod +x "$out/Library/Homebrew/brew.sh"
    '';

  linuxOnly = value: if pkgs.stdenv.hostPlatform.isLinux then value else throw "Linux-only CI test";

  evalStandaloneHomeManager =
    {
      name,
      module,
    }:
    if home-manager == null then
      throw "home-manager input must be set for standalone Home Manager tests"
    else if home-manager-pkgs == null then
      throw "home-manager-pkgs must be set for standalone Home Manager tests"
    else
      home-manager.lib.homeManagerConfiguration {
        pkgs = home-manager-pkgs;
        modules = [
          self.homeManagerModules.nix-homebrew
          {
            home = {
              username = "runner";
              homeDirectory = "/tmp/nix-homebrew-${name}-home";
              stateVersion = linuxStateVersion;
            };
          }
          module
        ];
      };

  wrapStandaloneHomeManagerTest =
    {
      name,
      homeConfiguration,
      script ? "${pkgs.coreutils}/bin/true",
    }:
    {
      config.system.build.ci-script = makeCiScript {
        name = "${name}.sh";
        requiredPaths = [ homeConfiguration.activationPackage ];
        inherit script;
      };
    };

  standaloneDisabledHomeManager =
    let
      homeConfiguration = evalStandaloneHomeManager {
        name = "standalone-home-manager-disabled";
        module = {
          nix-homebrew.enable = false;
        };
      };
      homePackageNames = map lib.getName homeConfiguration.config.home.packages;
      homeActivation = homeConfiguration.config.home.activation;
    in
    assert lib.all (assertion: assertion.assertion) homeConfiguration.config.assertions;
    assert !(builtins.elem "brew" homePackageNames);
    assert !(homeActivation ? setup-homebrew);
    wrapStandaloneHomeManagerTest {
      name = "standalone-home-manager-disabled";
      inherit homeConfiguration;
    };

  standaloneEnabledHomeManager =
    let
      prefix = "/tmp/nix-homebrew-standalone-home-manager-enabled-prefix";
      fakeBrew = makeFakeBrewPackage "standalone-home-manager-enabled";
      homeConfiguration = evalStandaloneHomeManager {
        name = "standalone-home-manager-enabled";
        module =
          { lib, ... }:
          {
            nix-homebrew = {
              enable = true;
              package = fakeBrew;
              patchBrew = false;
              mutableTaps = true;
              prefixes = lib.mkForce {
                ${prefix} = {
                  enable = true;
                  library = "${prefix}/Homebrew/Library";
                  taps = { };
                };
              };
            };
          };
      };
      homePackageNames = map lib.getName homeConfiguration.config.home.packages;
      homeActivation = homeConfiguration.config.home.activation;
    in
    assert lib.all (assertion: assertion.assertion) homeConfiguration.config.assertions;
    assert builtins.elem "brew" homePackageNames;
    assert homeActivation ? setup-homebrew;
    wrapStandaloneHomeManagerTest {
      name = "standalone-home-manager-enabled";
      inherit homeConfiguration;
    };

  standaloneHomeManagerActivation =
    let
      name = "standalone-home-manager-activation";
      prefix = "/tmp/nix-homebrew-${name}-prefix";
      homeDirectory = "/tmp/nix-homebrew-${name}-home";
      fakeBrew = makeFakeBrewPackage name;
      homeConfiguration = evalStandaloneHomeManager {
        inherit name;
        module =
          { lib, ... }:
          {
            nix-homebrew = {
              enable = true;
              package = fakeBrew;
              patchBrew = false;
              mutableTaps = true;
              prefixes = lib.mkForce {
                ${prefix} = {
                  enable = true;
                  library = "${prefix}/Homebrew/Library";
                  taps = { };
                };
              };
            };
          };
      };
      launcher =
        homeConfiguration.config.nix-homebrew.makeBinBrew
          homeConfiguration.config.nix-homebrew.prefixes.${prefix};
      activation = homeConfiguration.config.home.activation.setup-homebrew.data;
    in
    assert lib.all (assertion: assertion.assertion) homeConfiguration.config.assertions;
    wrapStandaloneHomeManagerTest {
      inherit name homeConfiguration;
      script = ''
        home_directory=${lib.escapeShellArg homeDirectory}
        prefix=${lib.escapeShellArg prefix}

        rm -rf "$home_directory" "$prefix"
        mkdir -p "$home_directory" "$prefix"

        if ${pkgs.gnugrep}/bin/grep -Eq '(/sudo |/runuser )' <<<${lib.escapeShellArg activation}; then
          >&2 echo "Home Manager activation contains a user-switching command"
          exit 1
        fi

        export HOME="$home_directory"
        export USER=runner
        export LOGNAME=runner

        first_output="$({ "${homeConfiguration.activationPackage}/activate"; } 2>&1)"
        printf '%s\n' "$first_output"
        if ${pkgs.gnugrep}/bin/grep -Fqi sudo <<<"$first_output"; then
          >&2 echo "standalone Home Manager activation requested sudo"
          exit 1
        fi

        second_output="$({ "${homeConfiguration.activationPackage}/activate"; } 2>&1)"
        printf '%s\n' "$second_output"

        test -L "$prefix/bin/brew"
        test "$(readlink "$prefix/bin/brew")" = ${lib.escapeShellArg launcher}

        config_output="$("$prefix/bin/brew" config)"
        printf '%s\n' "$config_output"
        ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg "HOMEBREW_PREFIX: ${prefix}"} <<<"$config_output"
      '';
    };

  makeHomeManagerActivationTest =
    {
      name,
      scenario,
    }:
    evalHomeManager (
      { config, pkgs }:
      let
        testUser = "__nix_homebrew_test_user__";
        prefix = "$TMPDIR/nix-homebrew-${name}";
        fakeBrew = pkgs.runCommandLocal "home-manager-fake-brew" { } ''
          mkdir -p "$out/Library/Homebrew"
          touch "$out/Library/Homebrew/brew.sh"
          chmod +x "$out/Library/Homebrew/brew.sh"
        '';
        launcher = config.nix-homebrew.makeBinBrew config.nix-homebrew.prefixes.${prefix};
        activation = config.home.activation.setup-homebrew;
      in
      {
        home.username = testUser;

        nix-homebrew = {
          enable = true;
          package = fakeBrew;
          patchBrew = false;
          user = lib.mkIf (scenario == "owner-mismatch") "root";
          mutableTaps = true;
          prefixes = lib.mkForce {
            ${prefix} = {
              enable = true;
              library = "${prefix}/Homebrew/Library";
              taps = { };
            };
          };
          trust.commands = [ "example/test" ];
        };

        system.build.ci-script =
          assert
            if scenario == "owner-mismatch" then
              lib.any (
                assertion:
                !assertion.assertion
                && assertion.message == "nix-homebrew.user must match home.username when using Home Manager"
              ) config.assertions
            else
              lib.all (assertion: assertion.assertion) config.assertions;
          pkgs.writeShellScript name ''
            set -euo pipefail

            prefix="${prefix}"
            rm -rf "$prefix"

            store_setup_script="$(${pkgs.gnused}/bin/sed -n 's/^run //p' <<<${lib.escapeShellArg activation})"
            actual_user="$(${pkgs.coreutils}/bin/id -un)"
            actual_group="$(${pkgs.coreutils}/bin/id -gn)"
            setup_script="$TMPDIR/${name}-setup-homebrew"

            materialize_setup_script() {
              configured_user="$1"
              ${pkgs.gnused}/bin/sed "s/${testUser}/$configured_user/g" \
                "$store_setup_script" >"$setup_script"
              chmod +x "$setup_script"
            }

            ${
              if scenario == "prepared" then
                ''
                  mkdir -p "$prefix"
                  materialize_setup_script "$actual_user"

                  if ${pkgs.gnugrep}/bin/grep -Eq '(/sudo |/runuser )' "$setup_script"; then
                    >&2 echo "Home Manager activation contains a user-switching command"
                    exit 1
                  fi

                  activation_output="$({ "$setup_script"; } 2>&1)"
                  printf '%s\n' "$activation_output"
                  if ${pkgs.gnugrep}/bin/grep -Fqi sudo <<<"$activation_output"; then
                    >&2 echo "prepared-prefix activation requested sudo"
                    exit 1
                  fi

                  test -L "$prefix/bin/brew"
                  test "$(readlink "$prefix/bin/brew")" = ${lib.escapeShellArg launcher}
                ''
              else if scenario == "missing" then
                ''
                  materialize_setup_script "$actual_user"

                  if output="$({ "$setup_script"; } 2>&1)"; then
                    >&2 echo "Home Manager activation unexpectedly initialized a missing prefix"
                    exit 1
                  fi

                  printf '%s\n' "$output"
                  ${pkgs.gnugrep}/bin/grep -Fq 'sudo install -d' <<<"$output"
                  ${pkgs.gnugrep}/bin/grep -Fq -- "-o $actual_user" <<<"$output"
                  ${pkgs.gnugrep}/bin/grep -Fq -- "-g '$actual_group'" <<<"$output"
                  test ! -e "$prefix"
                ''
              else if scenario == "non-writable" then
                ''
                  managed_path="$prefix/Homebrew/Library"
                  mkdir -p "$managed_path"
                  chmod 0555 "$managed_path"
                  materialize_setup_script "$actual_user"

                  if output="$({ "$setup_script"; } 2>&1)"; then
                    >&2 echo "Home Manager activation unexpectedly mutated a non-writable managed path"
                    exit 1
                  fi

                  printf '%s\n' "$output"
                  ${pkgs.gnugrep}/bin/grep -Fq "$managed_path is not writable" <<<"$output"
                  ${pkgs.gnugrep}/bin/grep -Fq 'sudo chown -R' <<<"$output"
                  test ! -w "$managed_path"
                  test ! -e "$prefix/.managed_by_nix_darwin"
                  test ! -e "$prefix/etc"
                ''
              else if scenario == "owner-mismatch" then
                ''
                  mkdir -p "$prefix"
                  ${pkgs.coreutils}/bin/cp "$store_setup_script" "$setup_script"
                  chmod +x "$setup_script"

                  if output="$({ "$setup_script"; } 2>&1)"; then
                    >&2 echo "Home Manager activation accepted a mismatched configured owner"
                    exit 1
                  fi

                  printf '%s\n' "$output"
                  ${pkgs.gnugrep}/bin/grep -Fq 'must run as the configured user root' <<<"$output"
                  test ! -e "$prefix/.managed_by_nix_darwin"
                ''
              else
                throw "unknown Home Manager activation test scenario: ${scenario}"
            }
          '';
      }
    );

  makeLinuxMigrationLayoutTest =
    {
      name,
      repositoryLayout,
    }:
    evalHomeManager (
      { config, pkgs }:
      let
        testUser = "__nix_homebrew_test_user__";
        prefix = "$TMPDIR/nix-homebrew-${name}";
        libraryRelative = if repositoryLayout == "standard" then "/Homebrew/Library" else "/Library";
        managedHomebrewPath = "${prefix}${libraryRelative}/Homebrew";
        expectedRepository = if repositoryLayout == "standard" then "${prefix}/Homebrew" else prefix;
        existingRepositorySetup =
          if repositoryLayout == "standard" then
            ''
              mkdir -p "$prefix/Homebrew/.git" "$prefix/Homebrew/Library/Homebrew"
            ''
          else if repositoryLayout == "prefix-root" then
            ''
              mkdir -p "$prefix/.git" "$prefix/Library/Homebrew"
            ''
          else
            throw "unknown Linux migration repository layout: ${repositoryLayout}";
        expectedMessage =
          if repositoryLayout == "standard" then
            "Looks like a standard Linux Homebrew installation"
          else
            "Looks like a Linux Homebrew installation with the prefix as the repository";
        fakeBrew = pkgs.runCommandLocal "linux-migration-fake-brew" { } ''
          mkdir -p "$out/Library/Homebrew"
          touch "$out/Library/Homebrew/brew.sh"
          chmod +x "$out/Library/Homebrew/brew.sh"
        '';
        nukeLogger = pkgs.writeShellScript "linux-migration-nuke-logger" ''
          set -euo pipefail

          printf '%s\n' "$1" >> "''${NIX_HOMEBREW_TEST_NUKE_LOG:?}"
          rm -rf -- "$1"
          mkdir -p -- "$1"
        '';
        baseTools = pkgs.callPackage (self + "/pkgs") { };
        setupScript =
          (import (self + "/modules/setup-linux.nix") {
            inherit lib pkgs config;
            activationMode = "home-manager";
          }).setupScript;
      in
      {
        home.username = testUser;

        nix-homebrew = {
          enable = true;
          autoMigrate = true;
          package = fakeBrew;
          patchBrew = false;
          mutableTaps = true;
          user = testUser;
          prefixes = lib.mkForce {
            ${prefix} = {
              enable = true;
              library = "${prefix}${libraryRelative}";
              taps = { };
            };
          };
          trust.commands = [ ];
          _tools = lib.mkForce (baseTools // { nuke-homebrew-repository = nukeLogger; });
        };

        system.build.ci-script =
          assert lib.all (assertion: assertion.assertion) config.assertions;
          pkgs.writeShellScript name ''
            set -euo pipefail

            prefix="${prefix}"
            expected_repository="${expectedRepository}"
            store_setup_script="${setupScript}"
            setup_script="$TMPDIR/${name}-setup-homebrew"
            nuke_log="$TMPDIR/${name}-nuke.log"
            actual_user="$(${pkgs.coreutils}/bin/id -un)"

            rm -rf "$prefix" "$setup_script" "$nuke_log"
            ${existingRepositorySetup}

            ${pkgs.gnused}/bin/sed "s/${testUser}/$actual_user/g" \
              "$store_setup_script" >"$setup_script"
            chmod +x "$setup_script"

            export NIX_HOMEBREW_TEST_NUKE_LOG="$nuke_log"

            if ! first_output="$({ "$setup_script"; } 2>&1)"; then
              printf '%s\n' "$first_output"
              >&2 echo "first Linux migration activation failed"
              exit 1
            fi

            printf '%s\n' "$first_output"
            ${pkgs.gnugrep}/bin/grep -Fq '${expectedMessage}' <<<"$first_output"
            ${pkgs.gnugrep}/bin/grep -Fq 'Attempting to migrate Homebrew installation...' <<<"$first_output"
            test -L "$prefix/bin/brew"
            test -L "${managedHomebrewPath}"
            test -e "$prefix/.managed_by_nix_darwin"
            test "$(${pkgs.coreutils}/bin/cat "$nuke_log")" = "$expected_repository"
            test "$(${pkgs.coreutils}/bin/wc -l < "$nuke_log")" -eq 1

            if ! second_output="$({ "$setup_script"; } 2>&1)"; then
              printf '%s\n' "$second_output"
              >&2 echo "second Linux migration activation failed"
              exit 1
            fi

            printf '%s\n' "$second_output"
            if ${pkgs.gnugrep}/bin/grep -Fq 'Attempting to migrate Homebrew installation...' <<<"$second_output"; then
              >&2 echo "second Linux migration activation unexpectedly retried migration"
              exit 1
            fi
            test "$(${pkgs.coreutils}/bin/wc -l < "$nuke_log")" -eq 1
          '';
      }
    );

  linuxInstallationModule =
    { config, ... }:
    {
      boot.loader.grub = {
        enable = true;
        devices = [ "nodev" ];
      };
      fileSystems."/" = {
        device = "tmpfs";
        fsType = "tmpfs";
      };
      nix-homebrew.enable = true;
      users.users.runner = {
        isNormalUser = true;
        group = "users";
        home = "/home/runner";
      };

      ci.requiredPaths = [ config.system.build.toplevel ];
      ci.postScript = ''
        sudo "${config.system.build.toplevel}/activate"
        "${config.nix-homebrew.brewLauncher}/bin/brew" config
      '';
    };

  launcherContentModule =
    { config, pkgs, ... }:
    let
      cfg = config.nix-homebrew;
      isArmDarwin = pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.isAarch64;
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

        ${lib.optionalString isArmDarwin ''
          router="$TMPDIR/brew-router"
          cp "${cfg.brewLauncher}/bin/brew" "$router"
          substituteInPlace "$router" \
            --replace-fail 'exec "/opt/homebrew/bin/brew" "$@"' \
              'printf "%s\n" /opt/homebrew; exit 0' \
            --replace-fail 'exec "/usr/local/bin/brew" "$@"' \
              'printf "%s\n" /usr/local; exit 0'

          check_route() {
            architecture="$1"
            expected_prefix="$2"
            actual_prefix="$(/usr/bin/arch "-$architecture" "$router" 2>&1 || true)"

            if [[ "$actual_prefix" != "$expected_prefix" ]]; then
              >&2 echo "$architecture launcher selected $actual_prefix"
              >&2 echo "expected $expected_prefix"
              failed=1
            fi
          }

          check_route arm64 /opt/homebrew
          check_route x86_64 /usr/local
        ''}

        (( failed == 0 ))
        touch "$out"
      '';
    in
    {
      nix-homebrew.enable = true;
      nix-homebrew.enableRosetta = lib.mkIf isArmDarwin true;
      system.stateVersion = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.mkForce "26.05");

      ci.script = lib.mkForce ''
        cat "${launcherContent}"
      '';
    };

  setupContentModule =
    { config, pkgs, ... }:
    let
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
      setupScript =
        if isDarwin then
          (import (self + "/modules/setup-darwin.nix") { inherit lib pkgs config; }).setupScript
        else
          (import (self + "/modules/setup-linux.nix") { inherit lib pkgs config; }).setupScript;
      setupContent = pkgs.runCommandLocal "setup-content" { } ''
        failed=0

        require_literal() {
          literal="$1"
          if ! ${pkgs.gnugrep}/bin/grep -Fq -- "$literal" "${setupScript}"; then
            >&2 echo "setup script does not contain required command: $literal"
            failed=1
          fi
        }

        reject_literal() {
          literal="$1"
          if ${pkgs.gnugrep}/bin/grep -Fq -- "$literal" "${setupScript}"; then
            >&2 echo "setup script contains forbidden command: $literal"
            failed=1
          fi
        }

        reject_bare_assignment() {
          variable="$1"
          command="$2"
          pattern="^$variable=\\((['\"])?$command(['\"])?([[:space:]]|\\))"
          if ${pkgs.gnugrep}/bin/grep -Eq -- "$pattern" "${setupScript}"; then
            >&2 echo "setup script assigns bare command $command to $variable"
            failed=1
          fi
        }

        ${
          if isDarwin then
            ''
              require_literal /usr/bin/id
              require_literal /usr/bin/find
              require_literal /usr/bin/readlink
              require_literal /bin/rm
              require_literal /bin/ln
              require_literal /usr/bin/rsync
              require_literal /usr/bin/stat
              require_literal /bin/chmod
              require_literal /usr/sbin/chown
              require_literal /usr/bin/chgrp
              require_literal /bin/mkdir
              require_literal /usr/bin/touch
              require_literal /usr/bin/install
              require_literal '/usr/bin/sudo -n -u runner -H "$BIN_BREW" trust --command example/test >/dev/null'
            ''
          else
            ''
              reject_literal /usr/bin/sudo
              reject_literal /usr/bin/rsync
              reject_literal '$(id '
              reject_literal '$(readlink '
              reject_literal '  ln -sfn'
              require_literal 'ID=(${pkgs.coreutils}/bin/id)'
              require_literal 'FIND=(${pkgs.findutils}/bin/find)'
              require_literal 'READLINK=(${pkgs.coreutils}/bin/readlink)'
              require_literal 'RM=(${pkgs.coreutils}/bin/rm)'
              require_literal 'LN=(${pkgs.coreutils}/bin/ln)'
              require_literal 'RSYNC=(${pkgs.rsync}/bin/rsync)'
              require_literal 'STAT_PRINTF=(${pkgs.coreutils}/bin/stat --printf)'
              require_literal 'CHMOD=(${pkgs.coreutils}/bin/chmod)'
              require_literal 'CHOWN=(${pkgs.coreutils}/bin/chown)'
              require_literal 'CHGRP=(${pkgs.coreutils}/bin/chgrp)'
              require_literal 'MKDIR=(${pkgs.coreutils}/bin/mkdir -p)'
              require_literal 'TOUCH=(${pkgs.coreutils}/bin/touch)'
              require_literal 'INSTALL=(${pkgs.coreutils}/bin/install -d -o root -g root -m 0755)'
              require_literal '${pkgs.util-linux}/bin/runuser -u runner -- "$BIN_BREW" trust --command example/test >/dev/null'
              reject_bare_assignment ID id
              reject_bare_assignment FIND find
              reject_bare_assignment READLINK readlink
              reject_bare_assignment RM rm
              reject_bare_assignment LN ln
              reject_bare_assignment RSYNC rsync
              reject_bare_assignment STAT_PRINTF stat
              reject_bare_assignment CHMOD chmod
              reject_bare_assignment CHOWN chown
              reject_bare_assignment CHGRP chgrp
              reject_bare_assignment MKDIR mkdir
              reject_bare_assignment TOUCH touch
              reject_bare_assignment INSTALL install
            ''
        }

        (( failed == 0 ))
        touch "$out"
      '';
    in
    {
      nix-homebrew.enable = true;
      nix-homebrew.mutableTaps = true;
      nix-homebrew.taps."example/homebrew-test" = pkgs.emptyDirectory;
      nix-homebrew.trust.commands = [ "example/test" ];
      system.stateVersion = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.mkForce "26.05");

      ci.script = lib.mkForce ''
        cat "${setupContent}"
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
  runtimeDepsModule =
    { config, pkgs, ... }:
    let
      cfg = config.nix-homebrew;
      prefixLauncher = cfg.makeBinBrew cfg.prefixes.${cfg.defaultLinuxPrefix};
      patchedBrew = cfg._brewPackage;
      glibcRb = "${patchedBrew}/Library/Homebrew/os/linux/glibc.rb";
      vendorInstall = "${patchedBrew}/Library/Homebrew/cmd/vendor-install.sh";
      runtimeDeps = pkgs.runCommandLocal "runtime-deps" { } ''
        failed=0

        # The prefix launcher filters the environment to a minimal PATH. On NixOS
        # /usr/bin/curl and /usr/bin/ldd do not exist, so the launcher's own
        # runtimePath must provide curl and ldd (used for curl-version detection
        # and glibc-version detection respectively).
        path_value="$(${pkgs.gnused}/bin/sed -n 's/^PATH="\([^"]*\)".*/\1/p' "${prefixLauncher}")"

        check_resolves() {
          tool="$1"
          resolved="$(PATH="$path_value" command -v "$tool" 2>/dev/null || true)"
          if [[ -z "$resolved" ]]; then
            >&2 echo "$tool not resolved in launcher PATH"
            failed=1
          fi
        }

        check_resolves curl
        check_resolves ldd

        # Homebrew hardcodes /usr/bin/ldd for glibc detection; nix-homebrew
        # patches it to resolve ldd via PATH instead (see modules/common.nix).
        if ${pkgs.gnugrep}/bin/grep -Fq '/usr/bin/ldd' "${glibcRb}"; then
          >&2 echo "glibc.rb still hardcodes /usr/bin/ldd"
          failed=1
        fi
        if ! ${pkgs.gnugrep}/bin/grep -Fq 'Utils.popen_read("ldd"' "${glibcRb}"; then
          >&2 echo "glibc.rb does not resolve ldd via PATH"
          failed=1
        fi
        if ${pkgs.gnugrep}/bin/grep -Fq '/usr/bin/ldd' "${vendorInstall}"; then
          >&2 echo "vendor-install.sh still hardcodes /usr/bin/ldd"
          failed=1
        fi

        (( failed == 0 ))
        touch "$out"
      '';
    in
    {
      nix-homebrew.enable = true;
      system.stateVersion = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.mkForce "26.05");

      ci.script = lib.mkForce ''
        cat "${runtimeDeps}"
      '';
    };

  runtimeDepsTest = makeTest { linuxModule = runtimeDepsModule; };
in
{
  disabled-system = makeTest {
    darwinModule = disabledSystemModule;
    linuxModule = disabledSystemModule;
  };

  disabled-home-manager = disabledHomeManager;

  standalone-home-manager-disabled = linuxOnly standaloneDisabledHomeManager;

  standalone-home-manager-enabled = linuxOnly standaloneEnabledHomeManager;

  standalone-home-manager-activation = linuxOnly standaloneHomeManagerActivation;

  home-manager-missing-prefix = makeHomeManagerActivationTest {
    name = "home-manager-missing-prefix";
    scenario = "missing";
  };

  home-manager-prepared-prefix = makeHomeManagerActivationTest {
    name = "home-manager-prepared-prefix";
    scenario = "prepared";
  };

  home-manager-non-writable-prefix = makeHomeManagerActivationTest {
    name = "home-manager-non-writable-prefix";
    scenario = "non-writable";
  };

  home-manager-owner-mismatch = makeHomeManagerActivationTest {
    name = "home-manager-owner-mismatch";
    scenario = "owner-mismatch";
  };

  linux-migration-layout = makeLinuxMigrationLayoutTest {
    name = "linux-migration-layout";
    repositoryLayout = "standard";
  };

  linux-migration-layout-prefix-root = makeLinuxMigrationLayoutTest {
    name = "linux-migration-layout-prefix-root";
    repositoryLayout = "prefix-root";
  };

  install = makeTest {
    linuxModule = linuxInstallationModule;
  };

  launcher-content = makeTest {
    darwinModule = launcherContentModule;
    linuxModule = launcherContentModule;
  };

  setup-content = makeTest {
    darwinModule = setupContentModule;
    linuxModule = setupContentModule;
  };

  runtime-deps = linuxOnly runtimeDepsTest;

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
