# Linux and Home Manager Architecture Design

## Goal

Extend nix-homebrew to support Linux through NixOS and Home Manager without
regressing nix-darwin, while keeping privileged installation separate from
unprivileged user activation.

## Supported integration modes

### nix-darwin

The nix-darwin module creates and manages the supported macOS prefixes during
system activation. It retains `/bin/bash` for prefix launchers so that
`arch -x86_64` continues to work on Apple Silicon.

### NixOS

The NixOS module creates and manages `/home/linuxbrew/.linuxbrew` during system
activation. Generated scripts use Nix store interpreters and tools and do not
depend on `/bin`, `/usr/bin`, or the activation process's ambient `PATH`.

### Home Manager

The Home Manager module is an unprivileged manager, not a system installer. It
can manage an existing supported prefix when that prefix and its managed
directories are writable by `home.username`. If the prefix has not been
bootstrapped, activation exits before making changes and prints a one-time
bootstrap command.

The module does not silently switch to a home-directory prefix because that
loses normal Homebrew bottle support. It does not invoke interactive sudo from
Home Manager activation. Users who intentionally want a nonstandard prefix can
configure `nix-homebrew.prefixes` explicitly and accept Homebrew's limitations.

## Module boundaries

`modules/common.nix` owns the public option schema and pure artifact builders:
the patched Homebrew source, prefix-specific `brew` scripts, and the unified
launcher. It does not register platform activation hooks.

`modules/darwin.nix`, `modules/linux.nix`, and `modules/home-manager.nix` own
their integration-specific defaults, package registration, shell integration,
and activation hooks. Every behavioral definition is guarded by
`nix-homebrew.enable`; importing any module with the default disabled setting
must evaluate successfully and produce no Homebrew package or activation hook.

`modules/setup-common.nix` owns platform-neutral prefix synthesis. Its caller
provides a structured platform toolset and privilege/user-switching behavior.
The generated script uses absolute executable paths throughout.

The Darwin and Linux setup wrappers own repository-layout detection and small
OS-specific permission differences. Standard Linux migration detects the
repository at `$HOMEBREW_PREFIX/Homebrew/.git`.

## Privilege and failure behavior

System activation runs as root. It creates the prefix and then performs
Homebrew trust operations as `nix-homebrew.user` through an injected
platform-specific user-switch command.

Home Manager activation never prompts for or opportunistically uses sudo. It
checks that the prefix exists and that the required paths are writable. A
missing or inaccessible prefix produces an actionable error before repository,
tap, or launcher mutation.

No setup path falls back from a failed privileged operation to an unprivileged
operation. Errors identify the affected prefix and the required remediation.

## Executable generation

On Linux, both the unified launcher and prefix-specific `brew` script use
`${pkgs.bash}/bin/bash`. On Darwin they use `/bin/bash` to preserve Rosetta
execution. Calls to `env`, `uname`, `git`, `rsync`, `stat`, `readlink`, and
permission tools use paths supplied by Nix packages or the Darwin platform
wrapper.

Homebrew's filtered runtime path contains the required Nix-provided bootstrap
tools. Host profile directories are not used as a substitute for declared
runtime dependencies.

## Compatibility

Existing nix-darwin option names and defaults remain compatible. The legacy
`.managed_by_nix_darwin` marker remains recognized to avoid forcing existing
installations through migration.

The flake continues to expose `darwinModules`, and adds working `nixosModules`
and `homeManagerModules`. Documentation for fork-only features references
`github:luojiansh/nix-homebrew`.

## Testing strategy

Evaluation tests cover disabled and enabled imports for nix-darwin, NixOS, and
Home Manager. Disabled imports must not access internal values that are defined
only when enabled.

NixOS tests build a complete NixOS configuration with a string
`system.stateVersion`, execute system activation, verify idempotent repeated
activation, and run the generated launcher. Tests cover mutable and declarative
taps, trust execution, and migration from the standard Linux repository
layout.

Home Manager tests evaluate both disabled and enabled configurations. The
activation test verifies that a missing supported prefix fails with the
bootstrap message and that a prepared writable prefix succeeds without sudo.

Darwin CI retains the existing migration and tap tests to catch regressions.
Formatting and whitespace checks run alongside Nix evaluation checks.

## Documentation

The README distinguishes system-managed installation from Home Manager
management, documents the one-time Linux bootstrap requirement, identifies
the supported default prefix, and points all fork-specific examples at the
fork. The Home Manager example follows the same contract.
