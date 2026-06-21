# Only used for development & CI
{
  inputs = {
    nixpkgs_unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs_26_05.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs_home_manager_unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs_home_manager_26_05.url = "github:NixOS/nixpkgs/nixos-26.05";

    nix-darwin_unstable.url = "github:nix-darwin/nix-darwin";
    nix-darwin_26_05.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";

    home-manager_unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs_home_manager_unstable";
    };
    home-manager_26_05 = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs_home_manager_26_05";
    };

    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs_unstable";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs_unstable) lib;

      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      releases = {
        "unstable" = {
          nixpkgs = inputs.nixpkgs_unstable;
          nix-darwin = inputs.nix-darwin_unstable;
          home-manager = inputs.home-manager_unstable;
          homeManagerNixpkgs = inputs.nixpkgs_home_manager_unstable;
          linuxStateVersion = "26.05";
        };
        "26.05" = {
          nixpkgs = inputs.nixpkgs_26_05;
          nix-darwin = inputs.nix-darwin_26_05;
          home-manager = inputs.home-manager_26_05;
          homeManagerNixpkgs = inputs.nixpkgs_home_manager_26_05;
          linuxStateVersion = "26.05";
        };
      };

      githubPlatforms = {
        "x86_64-linux" = "ubuntu-24.04";
        "aarch64-darwin" = "macos-26";
        "x86_64-darwin" = "macos-26";
      };

      matrix =
        let
          names = {
            release = builtins.attrNames releases;
            test = builtins.attrNames (
              import ./tests.nix {
                self = null;
                pkgs = null;
                nix-darwin = null;
                nixpkgs = null;
              }
            );
          };
        in
        lib.pipe names [
          lib.cartesianProduct
          (map (setup: {
            name = "${setup.test}-${setup.release}";
            value = setup;
          }))
          lib.listToAttrs
        ];

      forAllSystems =
        f: lib.genAttrs supportedSystems (system: f inputs.nixpkgs_unstable.legacyPackages.${system});

      makeCi =
        { self, brew-src }:
        let
          assembleTest =
            {
              system,
              release,
              test,
            }:
            let
              inputs' = releases.${release};
              pkgs = inputs'.nixpkgs.legacyPackages.${system};
              tests = import ./tests.nix {
                inherit self pkgs;
                inherit (inputs') nixpkgs;
                inherit (inputs') nix-darwin;
                inherit (inputs') home-manager linuxStateVersion;
                home-manager-pkgs = inputs'.homeManagerNixpkgs.legacyPackages.${system};
              };
            in
            tests.${test};

          enabledMatrixForSystem =
            system:
            lib.filterAttrs (
              _: setup:
              (builtins.tryEval (assembleTest {
                inherit system;
                inherit (setup) release test;
              })).success
            ) matrix;

          ciTests = lib.genAttrs supportedSystems (
            system:
            lib.mapAttrs (
              name:
              { release, test }:
              assembleTest {
                inherit system release test;
              }
            ) (enabledMatrixForSystem system)
          );
          checks = lib.mapAttrs (
            system: tests: lib.mapAttrs (name: test: test.config.system.build.ci-script) tests
          ) ciTests;
        in
        {
          inherit ciTests checks;
          packages = forAllSystems (
            pkgs:
            pkgs.callPackages (self + "/pkgs") {
              inherit brew-src;
            }
          );
          devShells = forAllSystems (pkgs: {
            default = pkgs.mkShell {
              nativeBuildInputs = with pkgs; [
                nixfmt
              ];

              BREW_SRC = brew-src;
            };
          });
          githubActions = inputs.nix-github-actions.lib.mkGithubMatrix {
            inherit checks;
            platforms = githubPlatforms;
          };
        };
    in
    {
      inherit makeCi;
    };
}
