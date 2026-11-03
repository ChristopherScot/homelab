You are reworking $repo pull request #$pr in $dir, which an independent
review panel declined to merge. Non-interactive: nobody can answer
questions, so make reasonable decisions and record them in the PR.

This is a revision, not a fresh start. The branch, the PR and the Kaneo
card ($task) already exist and stay as they are — push to the same branch
so the existing PR updates.

1. Read the objection first, before the code:
     gh pr view $pr --repo $repo --comments
   The panel's verdict is in the most recent comment headed "Nightly
   review". Read the whole thing. It was written by reviewers who had not
   seen the author's reasoning, which is the point of it.

2. Decide what the objection actually is. There are three kinds and they
   want different responses:
     - a correctness problem: fix it.
     - a missing or ineffective test: add one, and verify it fails without
       the fix the way the original ticket asked.
     - a design disagreement: you may keep your approach, but you must say
       why in the PR body. Do not silently comply with a reviewer you think
       is wrong, and do not silently ignore one. Either is how a PR gets
       reworked three times over the same point.

3. If the objection is that the change should not be made at all, do not
   force it through. Say "ABANDONED: <reason>" and stop — a human will see
   the card.

4. Make the smallest change that answers the objection. Do not take the
   opportunity to refactor neighbouring code, rename things, or improve
   something the panel did not raise: a rework that arrives larger than the
   change it revises is a rework nobody can review.

5. Run the project's own test command (make test if there is a Makefile,
   otherwise go test ./...). It must pass.

6. Run $ROUNDS rounds of review as the original author did: invoke
   go-idioms-reviewer, 100-go-mistakes-reviewer,
   pragmatic-programmer-reviewer, philosophy-of-software-design-reviewer on
   your diff. (For a non-Go repo, only the latter two.) Apply what you
   agree with; record what you decline and why.

7. Push to the same branch. Then comment on the PR with what you changed in
   response to each point the panel raised, and what you declined. This
   comment is what the next panel reads first, so it is the difference
   between a second review that engages with the revision and one that
   re-derives the same objection.

8. Do not merge. Do not touch main. Do not open a new PR.
