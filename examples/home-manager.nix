# Example Home Manager configuration for nix-homebrew
#
# Add this to your home-manager configuration:
#
# In your flake.nix inputs:
# {
#   inputs = {
#     nix-homebrew.url = "github:luojiansh/nix-homebrew";
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
#   # On Linux, create the default prefix once before activation:
#   # sudo install -d -o yourname -g "$(id -gn yourname)" -m 0755 /home/linuxbrew/.linuxbrew
#
#   nix-homebrew = {
#     enable = true;
#     # user automatically defaults to home.username
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
    # Home Manager manages an existing writable prefix.
    # On Linux, bootstrap /home/linuxbrew/.linuxbrew once with sudo first.
    # user automatically defaults to config.home.username
    # Optional: Disable mutable taps to have only declarative taps
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
