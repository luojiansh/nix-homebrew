# Example Home Manager configuration for nix-homebrew
#
# Add this to your home-manager configuration:
#
# In your flake.nix inputs:
# {
#   inputs = {
#     nix-homebrew.url = "github:zhaofengli/nix-homebrew";
#     home-manager = {
#       url = "github:nix-community/home-manager";
#       inputs.nixpkgs.follows = "nixpkgs";
#     };
#     # (...)
#   };
# }
#
# In your home-manager configuration:
# {
#   home.username = "yourname";
#   home.homeDirectory = "/Users/yourname";
#   # or on Linux:
#   # home.homeDirectory = "/home/yourname";
#
#   imports = [
#     nix-homebrew.homeManagerModules.nix-homebrew
#   ];
#
#   nix-homebrew = {
#     enable = true;
#     user = "yourname";
#     # Optional: Declare taps
#     # taps = {
#     #   "homebrew/homebrew-core" = pkgs.fetchFromGitHub {
#     #     owner = "homebrew";
#     #     repo = "homebrew-core";
#     #     rev = "...";
#     #     hash = "...";
#     #   };
#     # };
#   };
# }

{ pkgs, ... }:
{
  nix-homebrew = {
    enable = true;
    user = "yourname";
    # Optionally disable mutable taps to have only declarative taps
    # mutableTaps = false;
    # Optional: Automatically migrate existing Homebrew installation
    # autoMigrate = true;
    # Optional: Declare taps
    # taps = {
    #   "homebrew/homebrew-core" = pkgs.fetchFromGitHub {
    #     owner = "homebrew";
    #     repo = "homebrew-core";
    #     rev = "...";
    #     hash = "...";
    #   };
    # };
  };
}
