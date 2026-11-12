You are resuming work on Kaneo card $task in $dir, a clone of $repo.
Non-interactive: nobody can answer questions, so make reasonable decisions
and record them in the PR body.

A previous run committed $resume_ahead change(s) to the branch
$KANEO_BRANCH_PREFIX$task and stopped before opening a pull request. It
was not interrupted because anything was wrong — a usage limit, a
timeout, or a node going away all end a run mid-flight. The branch is
already checked out.

1. Find out what was already done before changing anything:
     git log --oneline origin/HEAD..HEAD
     git diff --stat origin/HEAD...HEAD
   Read the diff itself, not just the stat. The commit messages say what
   the previous run believed it was doing; the diff says what it did.

2. Read the card: kaneo task view $task
   Compare it against the diff. Decide what is genuinely left — not what
   you would have done differently. Rewriting work that is already
   correct wastes the run that produced it and makes the change harder to
   review.

3. If the previous run's commit messages mention review rounds, those
   rounds happened and their findings are already applied. Do not repeat
   them. Run the remaining rounds only.

4. If the work looks complete, say so and go straight to the tests and
   the pull request. A resumed run that finds nothing left to do is a
   success, not a wasted one.

5. Finish the ticket as the author would: the smallest correct change, a
   regression test that fails without the fix, and the project's own test
   command passing.

6. Push after every commit, including the first:
     git push
   This is what makes the next interruption cheap. The branch already
   exists upstream, so a plain push is enough.

7. Open the pull request with gh pr create, linking the card:
     Kaneo: $KANEO_WEB_URL/dashboard/task/$task
   Say in the body that the change was produced across more than one run,
   and what each contributed. A reviewer reading a 3,000-line diff is
   owed that context.

8. Do not merge. Do not touch main. Do not move the card yourself — the
   scripts move it, and a card moved twice skips a stage.
