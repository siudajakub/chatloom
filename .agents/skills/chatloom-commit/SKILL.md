---
name: chatloom-commit
description: Commit or publish scoped ChatLoom client changes when asked to commit, split microcommits, push to main, zakomitować zmiany, zrobić mikrocommity or wypchnąć na main.
---

# Publish ChatLoom changes

1. Work in the Git checkout containing `pubspec.yaml`. Confirm the current branch and `origin` with Git. On the maintainer's checkout, public `origin` is `siudajakub/chatloom`. The upstream FluffyChat remote and any private-history branches have different purposes.
2. Compare staged, unstaged and untracked paths against the requested scope and the latest local handoff. Review shared-file hunks separately when features overlap. Preserve existing staging for other work. Keep private handoffs, local documentation, signing and Firebase inputs, device logs, failure images and local build artifacts outside public commits.
3. Run the checks for the changed flow using the pinned toolchain in `docs/DEVELOPMENT.md`. Queue Flutter operations through `scripts/flutter-queue.py` on the devbox. Include `scripts/check-design-tokens.py` for UI changes. For microcommits, group the implementation and its regression tests by user-visible behavior. Inspect the staged diff and run `git diff --cached --check` before committing.
4. Push only on request. For publication to main, fetch the current remote branch and review the entire outgoing range, including earlier unpushed commits. Preserve concurrent work and use a normal fast-forward push. Confirm the published SHA with `git ls-remote origin refs/heads/main`. A build or service deployment requires its own request.
