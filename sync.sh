#!/usr/bin/env fish
if test (git branch --show-current) != main
    echo "Error: sync.sh must run on the main branch"
    exit 1
end

git fetch origin; or exit 1
# tags come from upstream only; --tags against both remotes can clobber each other
git fetch --tags upstream; or exit 1

# pre-rebase checks
if not git diff --quiet; or not git diff --cached --quiet
    echo "Error: working tree is not clean, commit or stash changes first"
    exit 1
end

if not git rev-parse --verify upstream/main >/dev/null 2>&1
    echo "Error: upstream/main not found"
    exit 1
end

if test -d (git rev-parse --git-dir)/rebase-merge; or test -d (git rev-parse --git-dir)/rebase-apply
    echo "Error: a rebase is already in progress"
    exit 1
end

git rebase upstream/main
if test $status -ne 0
    echo "Rebase hit conflicts, invoking Claude to resolve..."
    set -l resolve_prompt '/goal A rebase onto upstream/main is in progress and paused on conflicts. Resolve the conflicts and run git rebase --continue, repeating until the rebase is complete.

Conflict resolution rules:
- This branch is a patch stack on top of upstream/main. For each conflict, recover the intent of the commit being replayed (git show it) and preserve its pre-rebase behavior. Do not mechanically keep both sides.
- Never keep the same argument, import, or line from both sides of a conflict; duplicated arguments or use statements will not compile.
- When upstream adds code whose behavior a patch already covers or deliberately overrides, keep the patch line and drop the upstream one.
- For Cargo.lock conflicts, take upstream/main\'s side and run cargo check to regenerate entries for patched crates.
- Before every git rebase --continue, run: cargo check --workspace -q
  If it fails, fix the resolution before continuing, so every replayed commit at least compiles and the stack stays bisectable.'
    claude -p --dangerously-skip-permissions $resolve_prompt

    # verify the rebase actually completed before pushing
    if test -d (git rev-parse --git-dir)/rebase-merge; or test -d (git rev-parse --git-dir)/rebase-apply
        echo "Error: rebase still in progress after Claude, aborting..."
        git rebase --abort
        exit 1
    end
end

# catches the case where Claude aborted the rebase instead of completing it
if not git merge-base --is-ancestor upstream/main HEAD
    echo "Error: HEAD does not contain upstream/main, rebase did not complete"
    exit 1
end

# smoke and install artifact in one: auto-resolved conflicts must build before anything ships.
# dist = upstream's release recipe (fat LTO, codegen-units=1); avif decoding needs system dav1d;
# target-cpu=native and stripped symbols are fine for a binary that never leaves this machine
if not env RUSTFLAGS='-C target-cpu=native' CARGO_PROFILE_DIST_STRIP=symbols cargo build --profile dist --locked -p mcat --features avif
    echo "Error: cargo build failed after rebase, not pushing"
    exit 1
end

git push origin --force-with-lease; or exit 1
# keep fork tags current with upstream releases
git push origin --tags; or exit 1

# install: plain binary copy; cargo install would rebuild in its own staging dir
set -l installed ~/.cargo/bin/mcat
if cmp -s target/dist/mcat $installed
    echo "mcat already up to date at $installed, skipping install"
else
    install -m755 target/dist/mcat $installed; or exit 1
end

# a leftover mcat earlier in PATH (e.g. homebrew) silently shadows the install;
# deleting needs write permission on the directory, not the file
set -l resolved (command -v mcat)
if test "$resolved" != "$installed"
    echo "Removing shadowing copy at $resolved"
    if test -w (dirname $resolved)
        rm $resolved; or exit 1
    else
        sudo rm $resolved; or exit 1
    end
    if test (command -v mcat) != "$installed"
        echo "Error: mcat still resolves to "(command -v mcat)", not $installed"
        exit 1
    end
end

# smoke: the installed CLI must survive startup end to end
if not $installed --help >/dev/null
    echo "Error: installed mcat fails --help smoke check"
    exit 1
end

# keep the fish completion file in sync with the installed CLI;
# write via temp file so a failed generation never truncates the live one
set -l completion_file ~/.config/fish/completions/mcat.fish
if $installed --generate fish > $completion_file.tmp
    mv $completion_file.tmp $completion_file
else
    rm -f $completion_file.tmp
    echo "Error: failed to regenerate fish completions"
    exit 1
end
