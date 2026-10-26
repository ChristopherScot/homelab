You are testing $repo pull request #$pr in $dir. You are not reviewing the
code's style or structure — pod 1 does that. Your job is to find out where
it actually breaks.

Assume the change is plausible and the tests that ship with it pass. That
is the starting point, not the conclusion: a test written alongside a fix
tends to test the case the author already had in mind.

1. gh pr checkout $pr --repo $repo
2. Run the existing suite (make test, else go test ./...) and record the
   result. If it fails, stop and report that — nothing else matters yet.
3. Now go looking for what it misses. Work from the diff outward:
   - Boundaries: empty input, nil, zero, one, off-by-one at every limit.
   - Partial state: what if the process dies midway? What is left behind?
   - Concurrency: two of these at once. Shared state without a lock.
     For Go, run the suite with -race.
   - Errors: every error path the diff introduces — is it reachable, and
     does it leave things consistent? Force the failure if you can.
   - Inputs the author did not imagine: unicode, very long strings, paths
     with spaces, values that look like flags.
   - Idempotence: run it twice. Many of these tools are re-run constantly.
4. Write throwaway tests to prove each suspicion. You may add temporary
   files to do this. They are evidence, not deliverables.
5. For anything that reproduces, reduce it to the smallest case that
   still fails.

Then file what you found. For each distinct bug, one issue:

  gh issue create --repo $repo --label bug \\
    --title "<specific: what breaks, not 'possible issue in X'>" \\
    --body "<reproduction steps, observed vs expected, the minimal case,
             and which PR introduced it or exposed it>"

Rules on filing:
- One issue per bug. Do not bundle.
- Only file what you actually reproduced. A suspicion you could not
  trigger goes in the PR comment, not an issue — a speculative issue
  costs someone a real investigation.
- Check open issues first: gh issue list --repo $repo --state open.
  Do not file a duplicate.
- A bug that predates this PR is still worth filing; say so in the body.
- Do not fix anything. Do not push to the branch. Finding and reporting
  is the whole job.

Finally, comment on the PR with a short summary: what you exercised, what
held up, and links to any issues you filed. If you found nothing, say that
plainly and say what you tried — "no bugs found" is only useful alongside
the list of things that did not break.
