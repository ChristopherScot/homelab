You are working on Kaneo card $task in $dir, which is a clone of $repo.
Non-interactive: nobody can answer questions, so make reasonable decisions
and record them in the PR body.

The card is the ticket. There is no GitHub issue behind it and you should
not create one — the board at $KANEO_WEB_URL is where work is tracked, and
the card is what a human reads.

1. Read the card:  kaneo task view $task
   Read its comments too — a card sent back by the review panel, or
   annotated by Chris, carries the reasoning there.

2. First ask whether it should still be done at all. Investigate before
   deciding — read the code it refers to, check whether the described
   behaviour still exists, look at what has changed since it was filed.
   Decide it is obsolete only when the evidence is in the repo, not because
   it looks stale or is old. An old card describing a bug that is still
   there is still live work.

   If it genuinely should not be done, do NOT close or delete the card.
   Comment on it with what you checked and what you found:
     kaneo task comment $task "<what you checked, what you found, why it no longer needs doing>"
   then say "OBSOLETE: <reason>" and stop. A human moves it to Done or
   drags it back; deciding that for them is how a live ticket disappears.

   If it is ambiguous — it may be obsolete but you cannot prove it either
   way — comment with what you found and stop. Ambiguity is a reason to
   leave it for a human, not a reason to act.

3. If it should be done, decide if you can resolve it. Infrastructure and
   cluster work is in scope: this repo is GitOps, so prefer expressing the
   change as a manifest Argo will reconcile over an imperative kubectl
   command.
   Two things are out of scope — comment on the card saying so, write
   "SKIPPED: <reason>" and stop:
     - anything needing a credential or account only the owner can create
       (a GitHub App key, an OAuth login, a paid signup)
     - irreversible data loss: deleting a PV/PVC with reclaim Retain,
       dropping a database or table, force-pushing a shared branch,
       deleting a volume or snapshot. Propose it in the PR body instead and
       let a human run it.
   Reversible cluster changes are fine to make.

4. Branch: fix/$task
   The branch name is the only link between the pull request and the card
   that survives a force-push or a retitle, so it must be exactly this.

5. Implement the smallest correct fix.

6. Add a regression test that FAILS without your fix. Verify this by
   reverting the fix, running the test to see it fail, then restoring the
   fix. A test that passes either way certifies nothing.

7. Run the project's own test command (make test if there is a Makefile,
   otherwise go test ./...). It must pass.

8. Then run $ROUNDS rounds of review. Each round, invoke these subagents on
   your diff: go-idioms-reviewer, 100-go-mistakes-reviewer,
   pragmatic-programmer-reviewer, philosophy-of-software-design-reviewer.
   (For a non-Go repo, use only the latter two.)
   Apply findings you agree with. Where you disagree, say why in the PR body
   rather than silently complying.
   Aim for DRY, orthogonal code with honest abstraction boundaries. Do NOT
   add layers, interfaces or indirection the card does not need — an
   over-abstracted fix is a worse outcome than a plain one. Simplify
   existing code only where it is in the path of this fix.
   Re-run the tests after every round.

9. Push the branch and open a PR with gh pr create. If the repo has a
   template at .github/pull_request_template.md, follow its structure.
   The body must link the card so a reviewer can find the reasoning:
     Kaneo: $KANEO_WEB_URL/dashboard/task/$task
   Then: what changed, why, how the regression test was verified to fail
   without the fix, and any reviewer finding you declined with your
   reasoning.
   Do NOT write "Closes #..." — there is no issue, and the card is moved by
   the pipeline, not by GitHub.

10. Do not merge. Do not touch main. Do not move the card yourself — the
    scripts move it, and a card moved twice is a card that skips a stage.
