<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/github

A client for the [GitHub™](https://github.com/) REST API (version
`2022-11-28`) and its GraphQL™ endpoint, for github.com and GitHub Enterprise
Server. `call` reaches any REST endpoint, `getAll` follows the pages of a
list and `graphql` runs a GraphQL document. Typed verbs cover the daily
work: repositories, collaborators and webhooks; issues, comments, labels and
milestones; pull requests, reviews and merging; releases and their assets;
branches, tags and files; commits, commit statuses, check runs and Actions
(workflow runs, variables, secrets).

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/github/" as github;

def c as github.Client init github.client("github.com");
$c = github.withToken($c, strings.trim(fs.readString("/run/secrets/github")));
io.printf("%s\n", github.currentUser($c).login);
```

A `Client` is a value. `withToken` and the other `with*` functions return a
changed copy, so assign the result back to `$c`.

A repository is named `owner/name`: `"BurntSushi/ripgrep"`. Times are the
RFC 3339 strings GitHub sends.

## Errors

Every failure is a `github.GithubError` (kind `"github"`). The message names
the request, the HTTP status and GitHub's reason, and the status is the
`status` field, so a handler branches on it rather than on the text:

```text
github: GET /repos/me/missing: HTTP 404: Not Found
github: POST /repos/me/app/labels: HTTP 422: Validation Failed (name already_exists)
github: GET /user/repos: HTTP 403: API rate limit exceeded [rate limit exhausted; resets at 2026-11-14T18:00:00Z]
```

```jennifer
try {
    def r as github.Repository init github.repository($c, "me/missing");
} catch (e) {
    if ($e.kind == "github" and $e.status == 404) {
        io.printf("no such repository, or the token may not see it\n");
    } else {
        throw $e;
    }
}
```

A list past `MAX_PAGES` pages, a reply over its size cap, or a reply past
the JSON decoder's nesting or node caps, is kind `"limit"` instead, a deadline is kind `"timeout"`, and a connection closed
under a request is kind `"closed"` (each a plain `Error`). A network
failure (refused, reset, unreachable, DNS, TLS) is the `net.NetError` the
interpreter raised, kind `"net"`, passed on unchanged: its `reason` says
what failed, and `sent` false means GitHub never got the request, so it is
safe to repeat. A helper that takes a caught error of the deck is typed
`github.GithubError`, not `Error`.

## Secrets

`setSecret` seals the value with the repository's public key (libsodium's
sealed box, through Jennifer's `crypto` library) before sending it, so
GitHub stores what only the Actions runners can open. `secrets` lists the
names; a value can never be read back.

## Requirements

Jennifer 0.27.0 or newer, the default `jennifer` binary, and the `net`
capability.

## Trademarks

GitHub™ is a trademark of GitHub, Inc. GraphQL™ is a trademark of LF
Projects, LLC. Other product and company names may be trademarks of their
respective owners. They are used only to identify the products this deck
works with. This deck is an independent project, not affiliated with,
sponsored or endorsed by GitHub, Inc.
