<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Commits and CI

## Reporting a check

A CI system outside GitHub reports on a commit with a status per check:

```jennifer
github.setCommitStatus($c, "me/app", $sha, "pending", "ci/build", "building", $logUrl);
# ... build ...
github.setCommitStatus($c, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);

def s as github.CombinedStatus init github.combinedStatus($c, "me/app", "main");
io.printf("main is %s over %d checks\n", $s.state, len($s.statuses));
```

A state is `pending`, `success`, `error` or `failure`. A new status for the
same context replaces the old one in `combinedStatus`, whose state is
`failure`, `pending` or `success` (`pending` without any status);
`commitStatuses` keeps the history.

GitHub Actions report check runs, not statuses:

```jennifer
for (def r in github.checkRuns($c, "me/app", "main")) {
    io.printf("%s %s %s\n", $r.name, $r.status, $r.conclusion);
}
```

## Commits

```jennifer
for (def k in github.commits($c, "me/app", "main", "src")) {
    io.printf("%s %s\n", $k.sha, $k.message);
}
```

`commits` follows every page; `commit` fetches one by SHA, branch or tag.

## Actions

```jennifer
github.setVariable($c, "me/app", "REGION", "eu-west");
def id as int init github.dispatchWorkflow($c, "me/app", "release.yml", "main", {"level": "minor"});
if ($id != 0) {
    io.printf("%s\n", github.workflowRun($c, "me/app", $id).htmlUrl);
}
```

`dispatchWorkflow` needs a `workflow_dispatch` trigger in the workflow. On
github.com it asks for the new run and returns its id; an Enterprise Server
does not report it, and 0 comes back. An input given as `""` is sent as
`""`, not left to its default. Variable names are
letters, digits and `_`, do not start with a digit or `GITHUB_`, and GitHub
stores them in upper case; a value is not empty.

Secrets are set (`setSecret`), listed (`secrets`, names only) and deleted
(`deleteSecret`). `setSecret` seals the value on this machine with the
repository's public key: see [the introduction](index.md#secrets).
