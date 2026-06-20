# Linux Homebrew Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the NixOS and Home Manager modules safely install or manage Linux Homebrew while preserving nix-darwin compatibility.

**Architecture:** Keep option and artifact generation in `common.nix`, guard all integration behavior in platform adapters, and pass explicit platform tools and privilege behavior into the setup generator. NixOS and nix-darwin perform privileged bootstrap during system activation; Home Manager requires an existing writable prefix and fails with an actionable bootstrap command.

**Tech Stack:** Nix flakes and modules, nix-darwin, NixOS, Home Manager, Bash activation scripts, GitHub Actions.

---

## File responsibilities

- `modules/common.nix`: public options, patched Homebrew package, generated launchers, declared runtime dependencies.
- `modules/darwin.nix`: guarded nix-darwin defaults and activation registration.
- `modules/linux.nix`: guarded NixOS defaults and privileged activation registration.
- `modules/home-manager.nix`: guarded unprivileged Home Manager registration and bootstrap validation.
- `modules/setup-common.nix`: platform-neutral setup generation using injected absolute commands.
- `modules/setup-darwin.nix`: Darwin commands, user switching, migration detection, and Rosetta warning.
- `modules/setup-linux.nix`: Linux commands, user switching, and standard repository migration detection.
- `modules/utils-common.sh`: permission and prefix setup functions without sudo discovery or fallback.
- `modules/utils-darwin.sh`: absolute Darwin command definitions.
- `modules/utils-linux.sh`: replaceable absolute Linux command definitions.
- `ci/tests.nix`: system and Home Manager regression/integration tests.
- `ci/flake.nix`: release inputs, check outputs, and CI matrix construction.
- `README.md`, `examples/home-manager.nix`: supported usage and bootstrap contract.

### Task 1: Disabled imports are inert

**Files:**
- Modify: `ci/tests.nix`
- Modify: `modules/darwin.nix`
- Modify: `modules/linux.nix`
- Modify: `modules/home-manager.nix`

- [ ] **Step 1: Add disabled-module evaluation tests**

Add tests which force `environment.systemPackages`, activation scripts, and
`home.packages` with `nix-homebrew.enable = false`. Assert that no package or
activation entry from nix-homebrew is present.

- [ ] **Step 2: Verify the tests fail for the missing internal value**

Run the NixOS and Home Manager evaluations. Expected failure:
`The option nix-homebrew.brewLauncher was accessed but has no value defined`.

- [ ] **Step 3: Guard platform behavior**

Keep prefix and group defaults available to option merging, but wrap package
registration, shell integration, assertions that depend on enabled behavior,
and activation hooks in `lib.mkIf cfg.enable`.

- [ ] **Step 4: Verify disabled and enabled evaluations pass**

Run the focused evaluations and `nix flake check --no-build`. Expected: all
focused checks evaluate successfully.

- [ ] **Step 5: Commit**

```bash
git add ci/tests.nix modules/darwin.nix modules/linux.nix modules/home-manager.nix
git commit -m "fix: make disabled modules inert"
```

### Task 2: Generate executable Linux launchers

**Files:**
- Modify: `modules/common.nix`
- Modify: `ci/tests.nix`

- [ ] **Step 1: Add launcher-content tests**

Build or inspect the generated unified and prefix launchers for Linux and
Darwin. Assert Linux starts with the Nix-store Bash path and Darwin starts with
`/bin/bash`.

- [ ] **Step 2: Verify the Linux test fails**

Expected: both Linux scripts begin with `#!/bin/bash`.

- [ ] **Step 3: Implement platform-specific interpreters**

Use a single `bashPath` value in both script templates. Preserve
`dontPatchShebangs` because Darwin must retain `/bin/bash`, but emit
`#!${bashPath}` rather than a literal shebang. Use an absolute `uname` path in
the unified launcher.

- [ ] **Step 4: Declare the filtered Homebrew runtime**

Construct `runtimePath` from the Nix packages required by Homebrew bootstrap
instead of appending Nix profile directories. Include Bash, coreutils,
findutils, git, grep, sed, awk, and file.

- [ ] **Step 5: Verify launcher tests pass**

Run the focused derivation evaluations and formatting check.

- [ ] **Step 6: Commit**

```bash
git add modules/common.nix ci/tests.nix
git commit -m "fix: generate executable Linux brew launchers"
```

### Task 3: Inject setup tools and remove privilege fallback

**Files:**
- Modify: `modules/setup-common.nix`
- Modify: `modules/setup-darwin.nix`
- Modify: `modules/setup-linux.nix`
- Modify: `modules/utils-common.sh`
- Modify: `modules/utils-linux.sh`
- Modify: `ci/tests.nix`

- [ ] **Step 1: Add generated-script tests**

Assert the Linux setup script contains no `/usr/bin/sudo`, `/usr/bin/rsync`,
bare `id`, or bare `readlink`; assert the Darwin script retains its required
system paths.

- [ ] **Step 2: Verify the tests fail on sudo and rsync**

Expected: the generated Linux setup script includes both hard-coded paths.

- [ ] **Step 3: Define the setup generator interface**

Pass a command attribute set containing absolute paths for `id`, `readlink`,
`rm`, `rsync`, `stat`, `chmod`, `chown`, `chgrp`, `mkdir`, `touch`, and
`install`. Pass a `runAsUser` renderer separately so system integrations can
execute trust commands as the configured owner.

- [ ] **Step 4: Remove sudo discovery from common utilities**

Delete the `SUDO` fallback logic. Setup scripts execute directly under their
documented activation privilege. Permission helpers invoke only the injected
command arrays.

- [ ] **Step 5: Implement platform command sets**

Darwin uses its stable absolute system paths and `/usr/bin/sudo -n -u` for
trust. Linux uses Nix package paths, with `runuser` from util-linux for system
activation. Mutable tap synchronization uses the injected rsync path.

- [ ] **Step 6: Verify generated scripts and existing Darwin tests**

Run the focused script tests, all evaluation checks, and `nixfmt --check`.

- [ ] **Step 7: Commit**

```bash
git add modules/setup-common.nix modules/setup-darwin.nix modules/setup-linux.nix modules/utils-common.sh modules/utils-linux.sh ci/tests.nix
git commit -m "refactor: inject platform setup tools"
```

### Task 4: Enforce the Home Manager bootstrap boundary

**Files:**
- Modify: `modules/home-manager.nix`
- Modify: `modules/setup-common.nix`
- Modify: `modules/setup-darwin.nix`
- Modify: `modules/setup-linux.nix`
- Modify: `ci/tests.nix`

- [ ] **Step 1: Add Home Manager activation tests**

Add one test for a missing prefix and one for a prepared writable prefix. The
missing-prefix test must find the one-time `sudo install -d` bootstrap command
and must observe no attempted mutation. The prepared-prefix test must contain
no sudo invocation and must create the managed launcher.

- [ ] **Step 2: Verify the missing-prefix test fails unclearly**

Expected: activation proceeds into `install` and fails with permission denied
instead of the bootstrap message.

- [ ] **Step 3: Add an activation mode to setup generation**

System mode may initialize a missing prefix. Home Manager mode checks that each
enabled prefix exists, is a directory, and is writable before calling
`initialize_prefix`. It emits a command using the configured user and primary
group when bootstrap is required.

- [ ] **Step 4: Execute trust directly in Home Manager mode**

Because activation already runs as `home.username`, do not switch users or
invoke sudo. Keep system-mode user switching unchanged.

- [ ] **Step 5: Verify both activation modes**

Run the two Home Manager tests and the NixOS setup-script tests.

- [ ] **Step 6: Commit**

```bash
git add modules/home-manager.nix modules/setup-common.nix modules/setup-darwin.nix modules/setup-linux.nix ci/tests.nix
git commit -m "feat: require explicit Home Manager bootstrap"
```

### Task 5: Support standard Linux migration

**Files:**
- Modify: `modules/setup-linux.nix`
- Modify: `ci/tests.nix`

- [ ] **Step 1: Add a migration-layout test**

Create a fake existing repository at
`$HOMEBREW_PREFIX/Homebrew/.git`, enable `autoMigrate`, and assert that the nuke
tool receives `$HOMEBREW_PREFIX/Homebrew`.

- [ ] **Step 2: Verify detection fails**

Expected: activation prints the custom-installation error because it checks
`$HOMEBREW_PREFIX/.git`.

- [ ] **Step 3: Correct Linux detection**

Detect `$HOMEBREW_PREFIX/Homebrew/.git`, describe it as the standard Linux
layout, and assign `HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"`.

- [ ] **Step 4: Verify migration and idempotence tests pass**

Run the migration test twice and confirm the second setup completes without
attempting migration.

- [ ] **Step 5: Commit**

```bash
git add modules/setup-linux.nix ci/tests.nix
git commit -m "fix: migrate standard Linux Homebrew layouts"
```

### Task 6: Build real Linux and Home Manager CI coverage

**Files:**
- Modify: `ci/flake.nix`
- Modify: `ci/tests.nix`
- Modify: `flake.nix`
- Modify: `.github/workflows/ci.yaml`

- [ ] **Step 1: Add a Linux installation test to the matrix**

The test enables nix-homebrew, builds a complete NixOS toplevel, activates it
on the Ubuntu runner, runs activation a second time, and executes `brew config`
through the generated launcher.

- [ ] **Step 2: Verify the test exposes the stateVersion type error**

Force `config.system.build.toplevel`. Expected: NixOS rejects integer
`system.stateVersion = 6`.

- [ ] **Step 3: Set platform-specific state versions**

Use integer `6` only in nix-darwin test modules. Use the release string in
NixOS test modules. Do not place either value in the shared module.

- [ ] **Step 4: Add Home Manager release inputs and tests**

Evaluate disabled and enabled standalone Home Manager configurations on Linux.
Add an Ubuntu activation test that prepares a disposable writable prefix,
executes the activation package, and checks the launcher without sudo.

- [ ] **Step 5: Expose checks and formatting verification**

Expose evaluation derivations through the conventional `checks` flake output.
Add `nixfmt --check` and `git diff --check` to CI so formatting failures are
visible instead of hidden behind unknown custom outputs.

- [ ] **Step 6: Verify the generated matrix**

Run:

```bash
nix eval --json '.#githubActions.matrix' | jq '.include[] | select(.system == "x86_64-linux")'
```

Expected: Linux installation, migration/setup, Home Manager, and nuke tests are
present for supported releases.

- [ ] **Step 7: Commit**

```bash
git add ci/flake.nix ci/tests.nix flake.nix .github/workflows/ci.yaml
git commit -m "ci: exercise Linux and Home Manager activation"
```

### Task 7: Document supported installation and management

**Files:**
- Modify: `README.md`
- Modify: `examples/home-manager.nix`

- [ ] **Step 1: Add documentation assertions**

Search fork-specific examples for `github:zhaofengli/nix-homebrew` and require
zero matches. Require the README to mention the Home Manager bootstrap command
and the supported `/home/linuxbrew/.linuxbrew` prefix.

- [ ] **Step 2: Verify the assertions fail**

Expected: upstream URLs are found and no bootstrap instructions exist.

- [ ] **Step 3: Rewrite the quick start**

Point fork-only examples to `github:luojiansh/nix-homebrew`. Separate NixOS
system installation from Home Manager management. Document that Home Manager
requires a one-time privileged creation of the supported prefix and then runs
without sudo.

- [ ] **Step 4: Update the standalone example**

Make the bootstrap prerequisite explicit and remove wording that implies Home
Manager can install the global prefix by itself.

- [ ] **Step 5: Format and validate documentation**

Run `git diff --check` and the documentation assertions.

- [ ] **Step 6: Commit**

```bash
git add README.md examples/home-manager.nix
git commit -m "docs: explain Linux and Home Manager bootstrap"
```

### Task 8: Final verification and review

**Files:**
- Modify as required by verification failures only.

- [ ] **Step 1: Format all Nix files**

Run `nixfmt` on `flake.nix`, `ci/*.nix`, `modules/*.nix`, and `examples/*.nix`.

- [ ] **Step 2: Run static verification**

```bash
git diff --check upstream/main...HEAD
nixfmt --check flake.nix ci/*.nix modules/*.nix examples/*.nix
nix flake check --no-build --all-systems
```

- [ ] **Step 3: Run focused evaluations**

Evaluate disabled and enabled NixOS and Home Manager configurations and force
their package and activation outputs. Confirm no missing internal option values.

- [ ] **Step 4: Run buildable host tests**

Build every aarch64-darwin check available on the current host. Evaluate all
Linux derivations and record platform-mismatch limitations rather than claiming
they ran locally.

- [ ] **Step 5: Review the complete diff**

Compare `upstream/main...HEAD` for Darwin compatibility, option compatibility,
absolute Linux tools, guarded modules, test coverage, and documentation URLs.

- [ ] **Step 6: Commit verification fixes**

```bash
git add -u
git commit -m "chore: finalize Linux Homebrew support"
```
