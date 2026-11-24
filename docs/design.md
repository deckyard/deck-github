<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

A client for the GitHub™ REST API (version `2022-11-28`, `API_VERSION`) and
the GraphQL™ endpoint, for github.com and GitHub Enterprise Server:
repositories, their settings, collaborators and webhooks; issues, comments,
labels and milestones; pull requests, reviews and merging; releases and
assets; branches, tags, files and commits; commit statuses, check runs and
Actions (dispatch, runs, variables, secrets). `call`, `getAll` and `graphql`
reach every endpoint the typed functions do not cover.

Not in scope:

- **A fat typed wrapper of the whole API.** GitHub's API is enormous and
  grows; the typed verbs cover the everyday surface and the generic calls
  cover the rest, which ages better.
- **git itself.** The deck does not clone or run git (no `exec`); files,
  branches and tags are changed through the API. `@deckyard/git` drives the
  git program.
- **Forge-neutral code.** One API over GitHub, GitLab™ and Forgejo™ is
  `@deckyard/codehost`, which builds on this deck.
- **OAuth flows and App authentication.** The deck takes a ready token
  (personal, installation or Actions'); minting one is the caller's.

## Decisions

- **The forgejo deck's design.** Function names and argument order follow
  `@deckyard/forgejo` wherever GitHub has the concept, so code moves between
  the forges with little change and `codehost` maps them one to one. GitHub's
  own vocabulary wins where it differs: `User.name`, `Hook.name`,
  `Label.isDefault`, milestones addressed by number, review events
  `APPROVE` / `REQUEST_CHANGES` / `COMMENT`, `MERGE_STYLES` `merge` /
  `squash` / `rebase`, collaborator permissions `pull` to `admin`.
  `deleteLabel` takes the name and `deleteAsset` needs no release id, as
  GitHub's routes do. There is no `version` (github.com has none);
  `rateLimit` takes its place.
- **Pinned API version.** Every REST request sends
  `X-GitHub-Api-Version: 2022-11-28`, the JSON media type, a `User-Agent`
  (`USER_AGENT` by default; GitHub refuses a request without one) and the
  bearer token. A pinned version keeps replies stable across GitHub's
  changes.
- **Addresses.** `client` maps `github.com` and `api.github.com` to the
  public API, uploads and GraphQL hosts; any other host is an Enterprise
  Server under `/api/v3`, `/api/uploads` and `/api/graphql`. A trailing
  `/api/v3` is dropped, any other path refused.
- **Copy-returning configuration.** `Client` is a value changed with
  `withToken`, `withUserAgent`, `withCaCert`, `withInsecure`, `withTimeout`,
  `withRetries` and `withPlainHttp`.
- **The deck owns retries.** Only GETs are retried: a 5xx with a doubling
  wait from one second (raised to a stated `Retry-After`), or a rate limit
  (429, or 403 with `x-ratelimit-remaining: 0` or `retry-after`) after the
  wait GitHub states. A wait over `MAX_RETRY_WAIT_MS` (60 s) or one GitHub
  does not state fails at once, so a spent hourly limit is never hammered.
  Writes are never repeated.
- **Paging by `Link`.** `getAll` asks for `PAGE_SIZE` (100) entries unless
  the path sets `per_page`, follows `rel="next"`, refuses a next URL outside
  the client's API base, and stops at `MAX_PAGES` (1000). A page is a list,
  or an object with exactly one list member (`items`, `check_runs`,
  `workflow_runs`, ...); anything else is refused. GitHub caps some listings
  (Actions variables) at 30 whatever `per_page` says; paging covers it.
- **Tolerant readers, strict inputs.** Replies are read with accessors that
  turn an absent or `null` field into the zero value, so a field GitHub adds
  or omits does not break a call. Caller input is validated before it reaches
  a URL: repository and owner names, file paths (each segment encoded),
  refs and workflow names (validated, then encoded whole).
- **Redirects followed by the deck.** A GET follows up to 3 redirects (a
  renamed repository), relying on `http.send` to drop the token on another
  origin; writes follow none. `downloadAsset` follows GitHub's 302 to its
  asset storage itself, up to 5 hops, sending only `Accept` and `User-Agent`
  after the first, refusing a hop from https to http, and never printing a
  URL's query, which carries a signature.
- **Composite operations where GitHub needs several calls.**
  `createBranch` and `createTag` resolve their starting point to a commit
  first (an annotated tag creates the tag object, then the ref).
  `mergePullRequest` with `deleteBranch` deletes the head branch only when it
  lives in the same repository, never a fork's; a branch GitHub already
  deleted counts as done, and any other delete failure says the merge
  happened, so a caller does not retry it. `writeFile` finds the blob to
  replace first (none means create); `setVariable` updates and creates on a
  404.
- **Issue listings exclude pull requests**, which GitHub's issue endpoint
  mixes in.
- **`readFile` asks for the raw media type** and refuses a JSON answer,
  which is what GitHub sends for a directory or submodule; a real `.json`
  file comes as raw.
- **Secrets are sealed client-side.** `setSecret` fetches the repository's
  X25519 public key and seals the value with `crypto.wrap("nacl-sealedbox")`
  before sending, so GitHub stores only what the runners can open. Values are
  1 to `MAX_SECRET_BYTES` (48 KiB). Checked against PyNaCl's `SealedBox`.
- **`dispatchWorkflow` asks for run details** on github.com only (no
  Enterprise Server release documents it); elsewhere the run id is 0.
  `MAX_WORKFLOW_INPUTS` (25) is GitHub's own limit, checked before sending.
- **GraphQL through the bundled `graphql` module**, configured from the
  client (token, user agent, certificates, timeout, retries for queries
  only, and `withPlainHttp` as its `allowInsecureHttp`); the deck returns
  `/data`.

## Errors

Every refusal is a `GithubError{kind: "github", message, status}` with the
HTTP status (0 when nothing was answered or the deck refused before
sending). The message names the request, the status and GitHub's reason (its
`message`, or the `errors` entries), cut to 200 characters, plus a note when
a rate limit is spent or stated. Strings from callers and the server are cut
and stripped to printable ASCII before they appear in a message. A GraphQL
`errors` reply becomes a `GithubError` with status 200.

Passed on as their own kinds: `"limit"` (`MAX_PAGES`, a file or asset over
its cap, a reply past the JSON decoder's caps, which passes unchanged), `"timeout"` and `"closed"` (rebuilt with the request in front of
the message), and `"cancelled"` unchanged. A network failure (refused,
reset, unreachable, DNS, TLS, a close before any reply) is the interpreter's
`net.NetError` of kind `"net"`, passed on unchanged so its `reason`, `sent`
and `replied` fields survive. Other transport failures are a `GithubError`
with status 0. Callers branch on `kind` and `status`, never on
the message; a helper that takes a caught error is typed `GithubError`.

## Security and limits

- **Plain http only to loopback.** A client for `http://` reaches
  `127.0.0.1`, `localhost` or `[::1]` only, unless `withPlainHttp` allows it;
  the check runs before every request, so a refused client sends nothing and
  no token leaks. `http://github.com` is refused outright.
- **The token stays with GitHub.** Redirects to another origin drop it
  (the bundled `http` keeps only safe headers across origins), and asset
  downloads send no credential past the first hop.
- **Size caps.** `readFile` and `downloadAsset` take a cap: 0 means 64 MiB,
  a negative cap none, and a positive cap over `MAX_FILE_BYTES` (100 MB,
  GitHub's raw-file limit) is refused. A response past the cap is kind
  `"limit"`.
- **Deadlines.** Every request has a timeout (30 s by default).
- **Inputs.** Names, paths and refs are validated and encoded; an asset's
  content type must be a well-formed `type/subtype` with token parameters
  and no control characters.

## Testing and validation

- 51 tests against a loopback fake built on `httpd`, which records every
  request (method, path, query, headers, body) and answers scripted replies;
  a fake address is an Enterprise Server one, so Enterprise paths are what
  is exercised. The asset redirect test uses two fakes and asserts the
  storage one got no token. No network beyond loopback and one lookup of
  a `.invalid` name, no credentials.
- Retry timing is tested directly against the wait calculation rather than
  by sleeping.
- Checked live on 2026-11-14, anonymously (about 27 requests against public
  repositories): rate limit, repository, paging over three pages, releases,
  asset download with a checksum check through the storage redirect, raw
  file reads, directory listing, tags, commits, statuses, check runs, a
  merged pull request, labels, milestones, a 404, and GraphQL (refused
  without a token, as GitHub refuses anonymous GraphQL).
- Only against the fake: every write, search, `currentUser`, rate-limit
  refusals and retries, Enterprise Server paths and GraphQL with a token.
- The examples read github.com; CI only parses them.

## Known limitations and open questions

- The `edit*` functions leave out empty string fields, so they can keep a
  field but never clear it to `""`.
- No GitHub App or OAuth token minting; no webhook signature verification.
- Writes have not been exercised against the live service.

## Dependencies on the interpreter

- Floor `>=0.27.0`, for the UTF-8 codecs of `encoding.encode` / `decode`
  and `strings.replicate`; the default binary and the `net` capability (not
  `jennifer-tiny`).
- `crypto.wrap("nacl-sealedbox")` for `setSecret` (`jennifer`'s M28.58).
- `http.send` keeping only safe headers on a cross-origin redirect (M28.59).
- A reached cap as kind `"limit"` (M28.54), error structs accepted by
  lint's L104 (M28.50), and transport failures as `net.NetError` (M28.65).
- `graphql.j` from 0.27.0 refuses a token over plain http to another
  machine unless its `Client.allowInsecureHttp` is set, which
  `withPlainHttp` does.
