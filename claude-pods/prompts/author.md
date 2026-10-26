You are working in $dir on $repo issue #$num. Non-interactive: nobody can
answer questions, so make reasonable decisions and record them in the PR body.

1. Read the issue:  gh issue view $num --repo $repo
2. First ask whether it should still be done at all. Investigate before
   deciding — read the code it refers to, check whether the described
   behaviour still exists, look at what has changed since it was filed.
   Close it only when the evidence is in the repo, not because it looks
   stale or is old. An old ticket describing a bug that is still there is
   still a live ticket.

   Close it when, and only when, you can point at the proof:
     - already fixed: the behaviour it describes no longer happens, and
       you can name the commit or the current code that handles it
     - no longer applicable: the file, feature, dependency or service it
       concerns is gone
     - already covered: another open issue describes the same thing (link
       it and close this one as the duplicate)

   To close:
     gh issue close $num --repo $repo --reason "not planned" \
       --comment "<what you checked, what you found, why it no longer needs doing>"
   Say "CLOSED: <reason>" and stop. Do not open a PR.

   If it is genuinely ambiguous — the ticket may be obsolete but you
   cannot prove it either way — leave it open, comment with what you
   found, and stop. Ambiguity is a reason to leave it for a human, not a
   reason to close. A wrongly closed ticket is worse than a stale one:
   nobody goes looking for it again.

3. If it should be done, decide if you can resolve it. Infrastructure and
   cluster work is in scope:
   this repo is GitOps, so prefer expressing the change as a manifest Argo
   will reconcile over an imperative kubectl command.
   Two things are still out of scope — write "SKIPPED: <reason>" and stop:
     - anything needing a credential or account only the owner can create
       (a GitHub App key, an OAuth login, a paid signup)
     - irreversible data loss: deleting a PV/PVC with reclaim Retain, dropping
       a database or table, force-pushing a shared branch, deleting a volume
       or snapshot. Propose it in the PR body instead and let a human run it.
   Reversible cluster changes are fine to make.
4. Branch: fix/issue-$num
5. Implement the smallest correct fix.
6. Add a regression test that FAILS without your fix. Verify this by reverting
   the fix, running the test to see it fail, then restoring the fix. A test
   that passes either way certifies nothing.
7. Run the project's own test command (make test if there is a Makefile,
   otherwise go test ./...). It must pass.
8. Then run $ROUNDS rounds of review. Each round, invoke these subagents on
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
9. Push the branch and open a PR with gh pr create. If the repo has a
   template at .github/pull_request_template.md, follow its structure.
   The body MUST start with "Closes #$num" on its own line: GitHub only
   auto-closes the issue when the body carries that keyword, and without
   it the ticket stays open after the merge and gets picked up again
   tomorrow night. Then: what changed,
   why, how the regression test was verified to fail without the fix, and any
   reviewer finding you declined with your reasoning.
10. Do not merge. Do not touch main.
