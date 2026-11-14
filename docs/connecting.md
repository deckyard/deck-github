<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Connecting

## The address

`client` takes `github.com` or the host of a GitHub Enterprise Server:

```jennifer
def c as github.Client init github.client("github.com");
$c = github.client("github.example.com");          # Enterprise Server
$c = github.client("https://github.example.com/api/v3");
```

github.com is reached at `https://api.github.com`, its release uploads at
`https://uploads.github.com`. An Enterprise Server is reached at `/api/v3`,
`/api/graphql` and `/api/uploads` of its host. A server with its own CA is
trusted with `withCaCert`; `withInsecure` turns certificate checking off.

## Tokens

A fine-grained personal access token, a GitHub App installation token or
Actions' `GITHUB_TOKEN` all go in `withToken`. Give it only the permissions
the program needs: Contents to read and write files and releases, Issues,
Pull requests, Actions, Administration to create and delete repositories.

```jennifer
$c = github.withToken($c, os.getEnv("GITHUB_TOKEN"));
io.printf("%s\n", github.currentUser($c).login);
```

Without a token the client reads what is public. Every request carries the
API version (`X-GitHub-Api-Version: 2022-11-28`) and a `User-Agent`;
`withUserAgent` names the program instead of the deck.

## Rate limits

An anonymous caller gets 60 requests an hour per address, a token 5000.
`rateLimit` reports what is left without counting against it:

```jennifer
def rl as github.RateLimit init github.rateLimit($c);
io.printf("%d of %d left\n", $rl.remaining, $rl.limit);
```

A request refused for the rate limit fails with its status (403 or 429)
and says when the limit resets or how long GitHub asks to wait. GraphQL has
a limit of its own and refuses anonymous callers.

## Any endpoint

`call` takes the path under the REST base with its query string, and the
body as JSON text:

```jennifer
def topics as json.Value init github.call($c, "GET", "/repos/me/app/topics", "");
github.call($c, "PUT", "/repos/me/app/topics", '{"names":["jennifer","cli"]}');
```

`getAll` reads every page of a list, 100 entries a page, following the
`next` link GitHub sends in the `Link` header; it refuses a next page on
another server. A reply that wraps its list in an object (a search's
`items`, `workflow_runs`) gives that list. Past `MAX_PAGES` pages it fails
with kind `"limit"`.

```jennifer
for (def run in github.getAll($c, "/repos/me/app/actions/runs?status=failure")) {
    io.printf("%s\n", json.asString($run, "/html_url"));
}
```

## GraphQL

`graphql` sends a document with its variables and returns the reply's
`data`, with the client's token, certificates and timeout:

```jennifer
def v as json.Value init json.set(json.map(), "/owner", "BurntSushi");
def d as json.Value init github.graphql(
    $c, 'query($owner:String!){repositoryOwner(login:$owner){repositories{totalCount}}}', $v);
io.printf("%d\n", json.asInt($d, "/repositoryOwner/repositories/totalCount"));
```

A document is a raw `'...'` string: a cooked `"..."` one would read its
braces as interpolation. An `errors` reply fails as a `GithubError`, with
status 200 when GitHub answered 200 (as for `RATE_LIMITED`).

## Timeouts and retries

`withTimeout` sets each request's idle timeout, 30 s by default.
`withRetries` retries GETs answered 5xx (waiting 1 s, doubled each time) and
rate-limited GETs whose wait GitHub states, up to `MAX_RETRY_WAIT_MS`; a
longer or unknown wait fails at once. Writes are never retried.
