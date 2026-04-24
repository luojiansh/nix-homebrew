{
  description = "Homebrew installation manager for nix-darwin and NixOS";

  inputs = {
    brew-src = {
      url = "github:Homebrew/brew/5.1.7";
      flake = false;
    };
  };

  outputs = { self, brew-src }: let
    flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
    brewVersion = flakeLock.nodes.brew-src.original.ref;

    ci = (import ./ci/flake-compat.nix).makeCi {
      inherit self brew-src;
    };

    mkModuleWithDefaults = imports: { lib, ... }: {
      inherit imports;
      nix-homebrew.package = lib.mkOptionDefault (brew-src // {
        name = "brew-${brewVersion}";
        version = brewVersion;
      });
    };
  in {
    darwinModules = rec {
      nix-homebrew = mkModuleWithDefaults [
        ./modules/common.nix
        ./modules/darwin.nix
      ];

      default = nix-homebrew;
    };

    nixosModules = rec {
      nix-homebrew = mkModuleWithDefaults [
        ./modules/common.nix
        ./modules/linux.nix
      ];

      default = nix-homebrew;
    };

    homeManagerModules = rec {
      nix-homebrew = mkModuleWithDefaults [
        ./modules/common.nix
        ./modules/home-manager.nix
      ];

      default = nix-homebrew;
    };

    inherit (ci) packages devShells ciTests githubActions;
  };
}
