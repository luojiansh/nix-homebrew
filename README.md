# nix-homebrew

`nix-homebrew` manages Homebrew installations on macOS and Linux.
It pins the Homebrew version and optionally allows for declarative specification of taps.

`nix-homebrew` only installs Homebrew itself and does not manage any package installed by it.
For declarative formula/cask management on macOS, use the [`homebrew.*` options](https://daiderd.com/nix-darwin/manual/index.html#opt-homebrew.enable) in nix-darwin which work well in tandem with `nix-homebrew`.


## Quick Start

First of all, choose your platform module:

- macOS (with nix-darwin): `nix-homebrew.darwinModules.nix-homebrew`
- Linux (NixOS): `nix-homebrew.nixosModules.nix-homebrew`
- Home Manager (macOS or Linux): `nix-homebrew.homeManagerModules.nix-homebrew`

### Using with nix-darwin or NixOS

For macOS with nix-darwin, you must have [nix-darwin](https://github.com/LnL7/nix-darwin) configured already.
For Linux with NixOS, you must have [NixOS](https://nixos.org/) configured.

Add the following to your Flake inputs:

```nix
{
  inputs = {
    nix-homebrew.url = "github:luojiansh/nix-homebrew";

    # Optional: Declarative tap management
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    # (...)
  };
}
```

### Using with Home Manager

Home Manager manages an existing writable Homebrew prefix. It does not create or
re-own a global prefix for you.

On Linux, the supported default prefix is `/home/linuxbrew/.linuxbrew`. Create it
once before activating Home Manager:

```bash
sudo install -d -o yourname -g "$(id -gn yourname)" -m 0755 /home/linuxbrew/.linuxbrew
```

If the prefix already exists but is not writable by your Home Manager user, fix
it once before activating again:

```bash
sudo chown -R yourname:"$(id -gn yourname)" /home/linuxbrew/.linuxbrew
sudo chmod -R u+rwX /home/linuxbrew/.linuxbrew
```

Then add `nix-homebrew` to your flake inputs:

```nix
{
  inputs = {
    nix-homebrew.url = "github:luojiansh/nix-homebrew";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # (...)
  };
}
```

Then import the module in your Home Manager configuration:

```nix
{
  home-manager.users.yourname = { config, ... }: {
    imports = [
      nix-homebrew.homeManagerModules.nix-homebrew
    ];

    nix-homebrew = {
      enable = true;
      # user defaults to the current Home Manager user
      # Optional: Configure taps, autoMigrate, etc. (see examples below)
    };
  };
}
```

Or in a standalone `home.nix`:

```nix
{ config, ... }:
{
  imports = [
    nix-homebrew.homeManagerModules.nix-homebrew
  ];

  nix-homebrew = {
    enable = true;
    # Home Manager requires a writable existing prefix such as
    # /home/linuxbrew/.linuxbrew on Linux.
  };
}
```

## Configuration

### A. System Installation (nix-darwin or NixOS)

If you want nix-darwin or NixOS to install and manage Homebrew during system
activation, use the platform module and let the system own the bootstrap step.

For example:

```nix
{
  output = { self, nixpkgs, darwin, nix-homebrew, homebrew-core, homebrew-cask, ... }: {
    darwinConfigurations.macbook = {
      # (...)
      modules = [
        nix-homebrew.darwinModules.nix-homebrew
        {
          nix-homebrew = {
            # Install Homebrew under the default prefix
            enable = true;

            # Apple Silicon Only: Also install Homebrew under the default Intel prefix for Rosetta 2
            enableRosetta = true;

            # User owning the Homebrew prefix
            user = "yourname";

            # Optional: Declarative tap management
            taps = {
              "homebrew/homebrew-core" = homebrew-core;
              "homebrew/homebrew-cask" = homebrew-cask;
            };

            # Optional: Enable fully-declarative tap management
            #
            # With mutableTaps disabled, taps can no longer be added imperatively with `brew tap`.
            mutableTaps = false;

            # Optional: Declarative Homebrew tap trust entries.
            #
            # Note: The trust entries are _not_ removed if you remove them from those lists!
            # Use the `brew untrust` command to remove a trust entry.
            trust = {
              formulae = [ ];
              casks = [ ];
              commands = [ ];
              taps = [ ];
            };
          };
        }
        # Optional: Align homebrew taps config with nix-homebrew
        ({config, ...}: {
          homebrew.taps = builtins.attrNames config.nix-homebrew.taps;
        })
      ];
    };
  };
}
```

On NixOS, use `nix-homebrew.nixosModules.nix-homebrew` instead of the Darwin
module. On Linux, the default prefix follows Homebrew-on-Linux and is
`/home/linuxbrew/.linuxbrew`.

Once activated, a unified `brew` launcher will be created under `/run/current-system/sw/bin` that automatically selects the correct Homebrew prefix to use based on the architecture.
Run `arch -x86_64 brew` to install X86-64 packages through Rosetta 2.

With `nix-homebrew.mutableTaps = false`, taps can be removed by deleting the corresponding attribute in `nix-homebrew.taps` and activating the new configuration.

Setting `homebrew.taps` to equal `nix-homebrew.taps` attribute names reduces configuration mismatches. 

For non-official taps, Homebrew requires [explicit trust](https://docs.brew.sh/Tap-Trust).
You may use imperative `brew trust`/`brew untrust` commands, or configure `nix-homebrew` to add trust entries during activation:

```nix
nix-homebrew.trust = {
  formulae = [ "user/repo/formula" ];
  casks = [ "user/repo/cask" ];
  commands = [ "user/repo/command" ];

  # To quote upstream documentation:
  # > Trust a whole tap only when you are comfortable with all current and
  # > future formulae, casks and external commands from that tap being loaded
  # > by Homebrew.
  taps = [ "user/repo" ];
};
```
Note that when you remove items from those lists, the corresponding trust entries are _not_ removed automatically.
Use the `brew untrust` command to remove a trust entry.

### B. Existing Homebrew Installation

If you've already installed Homebrew with the official script, you can let `nix-homebrew` automatically migrate it:

```nix
{
  output = { self, darwin, nix-homebrew, ... }: {
    darwinConfigurations.macbook = {
      # (...)
      modules = [
        nix-homebrew.darwinModules.nix-homebrew
        {
          nix-homebrew = {
            # Install Homebrew under the default prefix
            enable = true;

            # Apple Silicon Only: Also install Homebrew under the default Intel prefix for Rosetta 2
            enableRosetta = true;

            # User owning the Homebrew prefix
            user = "yourname";

            # Automatically migrate existing Homebrew installations
            autoMigrate = true;
          };
        }
      ];
    };
  };
}
```

## Non-Standard Prefixes

On Linux, the default prefix follows Homebrew-on-Linux and is `/home/linuxbrew/.linuxbrew`.

Extra prefixes may be configured:

```nix
{
  nix-homebrew.prefixes = {
    "/some/prefix" = {
      library = "/some/prefix/Library";
      taps = {
        # ...
      };
    };
  };
}
```

Note that with a non-standard prefix, you will no longer be able to use most bottles (prebuilt packages).

## Declarative Taps

In Homebrew, the repo part of all taps always have `homebrew-` prepended.
- https://docs.brew.sh/Taps
- https://docs.brew.sh/Interesting-Taps-and-Forks

`brew tap <user>/<repo>` makes a clone of the repository at `https://github.com/<user>/homebrew-<repo>` into `$(brew --repository)/Library/Taps`.

When declaring taps, please ensure to name the key as a unique folder starting with `homebrew-`, e.g.:
```diff
       nix-homebrew.taps = {
-        "mtslzr/marmaduke-chromium" = inputs.marmaduke-chromium;
+        "mtslzr/homebrew-marmaduke-chromium" = inputs.marmaduke-chromium;
```
The exact GitHub `<user>/<repo>` should almost always work.
