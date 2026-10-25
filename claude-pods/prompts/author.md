You are working in $dir on $repo issue #$num. Non-interactive: nobody can
answer questions, so make reasonable decisions and record them in the PR body.

1. Read the issue:  gh issue view $num --repo $repo
2. Decide if you can resolve it. Infrastructure and cluster work is in scope:
   this repo is GitOps, so prefer expressing the change as a manifest Argo
   will reconcile over an imperative kubectl command.
   Two things are still out of scope — write "SKIPPED: <reason>" and stop:
     - anything needing a credential or account only the owner can create
       (a GitHub App key, an OAuth login, a paid signup)
     - irreversible data loss: deleting a PV/PVC with reclaim Retain, dropping
       a database or table, force-pushing a shared branch, deleting a volume
       or snapshot. Propose it in the PR body instead and let a human run it.
   Reversible cluster changes are fine to make.
3. Otherwise branch: fix/issue-$num
4. Implement the smallest correct fix.
5. Add a regression test that FAILS without your fix. Verify this by reverting
   the fix, running the test to see it fail, then restoring the fix. A test
   that passes either way certifies nothing.
6. Run the project's own test command (make test if there is a Makefile,
   otherwise go test ./...). It must pass.
7. Then run $ROUNDS rounds of review. Each round, invoke these subagents on
   your diff: go-idioms-reviewer, 100-go-mistakes-reviewer,
   pragmatic-programmer-reviewer, philosophy-of-software-design-reviewer.
   (For a non-Go repo, use only the latter two.)
   Apply findings you agree with. Where you disagree, say why in the PR body
   rather than silently complying.
   Aim for DRY, orthogonal code with honest abstraction boundaries. Do NOT
   add layers, interfaces or indirection the ticket does not need — an
   over-abstracted fix is a worse outcome than a plain one. Simplify existing
   code only where it is in the path of this fix.
   Re-run the tests after every round.
8. Push the branch and open a PR with gh pr create. If the repo has a
   template at .github/pull_request_template.md, follow its structure.
   The body MUST start with "Closes #$num" on its own line: GitHub only
   auto-closes the issue when the body carries that keyword, and without
   it the ticket stays open after the merge and gets picked up again
   tomorrow night. Then: what changed,
   why, how the regression test was verified to fail without the fix, and any
   reviewer finding you declined with your reasoning.
9. Do not merge. Do not touch main.
