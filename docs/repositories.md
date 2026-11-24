<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Repositories

## Finding and forking

```jennifer
for (def r in github.searchRepositories($c, "jennifer language:go stars:>10")) {
    io.printf("%s %d stars\n", $r.fullName, $r.stars);
}
def mine as github.Repository init github.forkRepository($c, "octocat/hello-world", "", "");
```

A search returns at most 1000 results. A fork is copied in the background;
it may look empty for a moment.

## Creating and settings

```jennifer
github.createRepository($c, "", "app", "An app for X", true);
github.editRepository($c, "me/app", "An app for X", "https://app.example.com");
github.setDefaultBranch($c, "me/app", "trunk");
github.setArchived($c, "me/old", true);
```

An owner `""` creates the repository under the token's account; an
organization's name creates it there. `""` keeps a text as it is. Anything else
`editRepository` does not cover is a `call` with `PATCH /repos/{owner}/{repo}`.

## Who may push

```jennifer
github.addCollaborator($c, "acme/app", "ada", "push");
for (def u in github.collaborators($c, "acme/app")) {
    io.printf("%s\n", $u.login);
}
github.removeCollaborator($c, "acme/app", "ada");
```

A permission is `pull`, `triage`, `push`, `maintain` or `admin`. On a
user's own repository GitHub™ sends an invitation the user must accept.

## Webhooks

```jennifer
def h as github.Hook init github.createHook($c, "me/app", "https://ci.example.com/hook", $secret, ["push", "pull_request"]);
github.deleteHook($c, "me/app", $h.id);
```

The hook posts JSON and signs it with the secret (`X-Hub-Signature-256`,
HMAC-SHA256).
