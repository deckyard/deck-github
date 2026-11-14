<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Issues and pull requests

## Issues

```jennifer
for (def i in github.issues($c, "me/app", "open")) {
    io.printf("#%d %s %v\n", $i.number, $i.title, $i.labels);
}
def made as github.Issue init github.createIssue($c, "me/app", "Nightly build failed", $log);
github.comment($c, "me/app", $made.number, "Fixed in 1.2.1.");
github.closeIssue($c, "me/app", $made.number);
```

`issues` leaves pull requests out, which GitHub's listing mixes in; the
state is `open`, `closed` or `all`. `closeIssue`, `reopenIssue`, `comment`,
`comments`, `editIssue`, `setAssignees`, `setMilestone` and the label verbs
work on pull requests too, which share the issue numbers.

`searchIssues` takes GitHub's search syntax and returns issues and pull
requests (`isPull`), at most 1000:

```jennifer
for (def i in github.searchIssues($c, "repo:me/app is:issue is:open label:bug")) {
    io.printf("#%d %s\n", $i.number, $i.title);
}
```

## Labels and milestones

```jennifer
github.createLabel($c, "me/app", "crash", "#b60205", "The program stops");
github.addIssueLabels($c, "me/app", 12, ["crash"]);
def m as github.Milestone init github.createMilestone($c, "me/app", "1.0", "", "2026-12-31T00:00:00Z");
github.setMilestone($c, "me/app", 12, $m.number);
github.editIssue($c, "me/app", 12, "Crash on start with an empty config", "");
```

Labels go by name: `deleteLabel` takes the name, and `setIssueLabels` and
`addIssueLabels` create a label that does not exist yet. `setIssueLabels`
replaces them all, `[]` clears them. A milestone goes by its `number`, and 0
in `setMilestone` takes an issue out of its milestone. `""` in `editIssue`
keeps the title or text.

## Pull requests

```jennifer
def pr as github.PullRequest init github.createPullRequest(
    $c, "me/app", "update-deps", "main", "Update dependencies", "");
if (github.pullRequest($c, "me/app", $pr.number).mergeable) {
    github.mergePullRequest($c, "me/app", $pr.number, "squash", true);
}
```

The head of a pull request from a fork is `user:branch`. GitHub computes
`mergeable` in the background: it is false until then, and in a listing.
`MERGE_STYLES` lists `merge`, `squash` and `rebase`; the repository's
settings decide which are allowed. Merging fails with HTTP 405 when the pull
request cannot be merged, and 409 when its head moved. With `deleteBranch`
the head branch is deleted after the merge when it is in the same
repository. A branch GitHub deleted itself ("Automatically delete head
branches") counts as deleted. When the merge succeeded but the delete
failed, the error says so (`github: merged #12, but deleting branch
"fix-crash" failed: ...`, with the delete's status): do not merge again.

## Reviews

```jennifer
github.requestReviewers($c, "me/app", $pr.number, ["ada"]);
for (def f in github.pullRequestFiles($c, "me/app", $pr.number)) {
    io.printf("%s +%d -%d\n", $f.filename, $f.additions, $f.deletions);
}
github.reviewPullRequest($c, "me/app", $pr.number, "APPROVE", "");
```

A review is `APPROVE`, `REQUEST_CHANGES` or `COMMENT`; the last two need a
text. A review's `state` reads `APPROVED`, `CHANGES_REQUESTED` or
`COMMENTED`. A token cannot approve its own pull request.
