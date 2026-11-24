<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# github cheatsheet

Every export of `@deckyard/github`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/github/" as github;
```

Every function that sends a request throws a `GithubError` (kind `"github"`,
with the HTTP `status`) when it fails; a list past `MAX_PAGES` pages, a reply
over its size cap or past the JSON decoder's caps is kind `"limit"`, a deadline kind `"timeout"`, a connection closed
under a request kind `"closed"`, and a network failure is a `net.NetError` (kind
`"net"`, with `reason`, `sent` and `replied`), passed on unchanged. A `repo` is
`owner/name`; a `number` is an issue or pull request number.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"github"` | the `kind` of every error the deck throws |
| `API_VERSION` | `"2022-11-28"` | the REST API version every request asks for |
| `PAGE_SIZE` | `100` | entries asked for per page |
| `MAX_PAGES` | `1000` | pages a list follows before it refuses |
| `MAX_RETRY_WAIT_MS` | `60000` | the longest wait a retried GET sleeps through |
| `MAX_SECRET_BYTES` | `49152` | the longest Actions secret value, GitHub™'s 48 KB |
| `USER_AGENT` | `"jennifer-deckyard-github"` | the default `User-Agent` |
| `MERGE_STYLES` | `["merge", "squash", "rebase"]` | the ways to merge a pull request |
| `MAX_FILE_BYTES` | `104857600` | the largest `maxBytes` of `readFile`, GitHub's 100 MB raw limit |
| `MAX_WORKFLOW_INPUTS` | `25` | the most inputs `dispatchWorkflow` sends |

## Types

### `Client`

A connection to github.com or a GitHub Enterprise Server.

| Field | Meaning |
|---|---|
| `url as string` | the REST base, `https://api.github.com` or `https://host/api/v3` |
| `uploadUrl as string` | where release assets go, `https://uploads.github.com` or `https://host/api/uploads` |
| `graphqlUrl as string` | the GraphQL™ endpoint |
| `token as string` | the token; "" for anonymous reads |
| `userAgent as string` | the `User-Agent` header |
| `tls as http.TlsOptions` | certificate checking |
| `timeoutMs as int` | the idle timeout of each request; 0 for 30 s |
| `retries as int` | retries of a GET answered 5xx or rate limited |
| `allowPlainHttp as bool` | whether plain `http` to another machine is allowed (the token then crosses the network in clear) |

### `User`

An account.

| Field | Meaning |
|---|---|
| `id as int` | the account id |
| `login as string` | the user name |
| `name as string` | the display name |
| `email as string` | the public e-mail address |
| `isAdmin as bool` | whether it administers the server (`site_admin`) |

### `Repository`

A repository.

| Field | Meaning |
|---|---|
| `id as int` | the repository id |
| `owner as string` | the owning user or organization |
| `name as string` | the name |
| `fullName as string` | `owner/name` |
| `description as string` | the description |
| `isPrivate as bool` | whether it is private |
| `isFork as bool` | whether it is a fork |
| `isArchived as bool` | whether it is archived |
| `defaultBranch as string` | e.g. `main` |
| `htmlUrl as string` | its page |
| `cloneUrl as string` | the HTTPS clone URL |
| `sshUrl as string` | the SSH clone URL |
| `stars as int` | the star count |
| `openIssues as int` | open issues and pull requests |
| `updated as string` | last update, RFC 3339 |

### `Issue`

An issue.

| Field | Meaning |
|---|---|
| `number as int` | the number within the repository |
| `title as string` | the title |
| `body as string` | the text, Markdown |
| `state as string` | `open` or `closed` |
| `author as string` | who opened it |
| `labels as list of string` | label names |
| `assignees as list of string` | assigned user names |
| `comments as int` | the comment count |
| `isPull as bool` | whether it is a pull request |
| `created as string` | RFC 3339 |
| `updated as string` | RFC 3339 |
| `closed as string` | RFC 3339; "" while open |
| `htmlUrl as string` | its page |

### `Comment`

A comment on an issue or pull request.

| Field | Meaning |
|---|---|
| `id as int` | the comment id |
| `author as string` | who wrote it |
| `body as string` | the text, Markdown |
| `created as string` | RFC 3339 |
| `htmlUrl as string` | its place on the page |

### `PullRequest`

A pull request.

| Field | Meaning |
|---|---|
| `number as int` | the number within the repository |
| `title as string` | the title |
| `body as string` | the text, Markdown |
| `state as string` | `open` or `closed` |
| `author as string` | who opened it |
| `head as string` | the branch with the changes |
| `base as string` | the branch it merges into |
| `headSha as string` | the commit at the head |
| `isDraft as bool` | whether it is a draft |
| `mergeable as bool` | whether GitHub can merge it; false while GitHub is still computing it, and in a listing |
| `merged as bool` | whether it is merged |
| `mergeSha as string` | the merge commit, or the test merge commit of an open one; "" when there is none |
| `htmlUrl as string` | its page |

### `Asset`

A file attached to a release.

| Field | Meaning |
|---|---|
| `id as int` | the asset id |
| `name as string` | the file name |
| `contentType as string` | the media type it was uploaded with |
| `size as int` | bytes |
| `downloads as int` | the download count |
| `downloadUrl as string` | the browser download link |
| `apiUrl as string` | the asset's API URL, which `downloadAsset` reads |

### `Release`

A release.

| Field | Meaning |
|---|---|
| `id as int` | the release id |
| `tag as string` | the tag it is for |
| `name as string` | the title |
| `body as string` | the notes, Markdown |
| `isDraft as bool` | whether it is a draft |
| `isPrerelease as bool` | whether it is a pre-release |
| `created as string` | RFC 3339 |
| `published as string` | RFC 3339; "" for a draft |
| `htmlUrl as string` | its page |
| `assets as list of Asset` | the attached files |

### `Branch`

A branch.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `isProtected as bool` | whether a protection rule covers it |

### `Tag`

A tag.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `message as string` | the annotation `createTag` wrote; "" in a listing, which does not carry it |

### `CommitStatus`

The status a CI system set on a commit.

| Field | Meaning |
|---|---|
| `context as string` | which check it is, e.g. `ci/build` |
| `state as string` | `pending`, `success`, `error` or `failure` |
| `description as string` | a short text |
| `targetUrl as string` | where the details are |
| `creator as string` | who set it |
| `created as string` | RFC 3339 |

### `CombinedStatus`

The statuses of a commit, combined.

| Field | Meaning |
|---|---|
| `state as string` | `failure`, `pending` or `success`; `pending` when there are none |
| `statuses as list of CommitStatus` | the latest status per context |

### `CheckRun`

A check run on a commit, as GitHub Actions and other apps report them.

| Field | Meaning |
|---|---|
| `id as int` | the check run id |
| `name as string` | e.g. `build` |
| `status as string` | `queued`, `in_progress`, `completed`, `waiting`, `requested` or `pending` |
| `conclusion as string` | `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out` or `action_required`; "" until completed |
| `htmlUrl as string` | its page |
| `started as string` | RFC 3339 |
| `completed as string` | RFC 3339; "" until completed |

### `WorkflowRun`

A run of an Actions workflow.

| Field | Meaning |
|---|---|
| `id as int` | the run id |
| `name as string` | the workflow's name |
| `event as string` | what started it, e.g. `push`, `workflow_dispatch` |
| `status as string` | e.g. `queued`, `in_progress`, `completed` |
| `conclusion as string` | e.g. `success`, `failure`; "" until completed |
| `headBranch as string` | the branch it ran on |
| `headSha as string` | the commit it ran on |
| `htmlUrl as string` | its page |
| `created as string` | RFC 3339 |

### `Commit`

A commit.

| Field | Meaning |
|---|---|
| `sha as string` | the commit SHA |
| `message as string` | the commit message |
| `author as string` | the author's name, as Git™ records it |
| `authorEmail as string` | the author's e-mail address |
| `date as string` | the author date, RFC 3339 |
| `htmlUrl as string` | its page |

### `Label`

A label of a repository.

| Field | Meaning |
|---|---|
| `id as int` | the label id |
| `name as string` | the name, e.g. `bug` |
| `color as string` | the colour, e.g. `#d73a4a` |
| `description as string` | the description |
| `isDefault as bool` | whether GitHub created it with the repository |

### `Milestone`

A milestone of a repository. GitHub addresses it by its `number`.

| Field | Meaning |
|---|---|
| `number as int` | the number within the repository |
| `title as string` | the title |
| `description as string` | the description |
| `state as string` | `open` or `closed` |
| `dueOn as string` | RFC 3339; "" without a due date |
| `openIssues as int` | open issues in it |
| `closedIssues as int` | closed issues in it |

### `Review`

A review of a pull request.

| Field | Meaning |
|---|---|
| `id as int` | the review id |
| `author as string` | who reviewed |
| `state as string` | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` or `PENDING` |
| `body as string` | the text, Markdown |
| `commitId as string` | the commit it reviewed |
| `submitted as string` | RFC 3339 |

### `ChangedFile`

A file a pull request changes.

| Field | Meaning |
|---|---|
| `filename as string` | the path |
| `status as string` | `added`, `removed`, `modified`, `renamed`, `copied`, `changed` or `unchanged` |
| `additions as int` | lines added |
| `deletions as int` | lines deleted |
| `previousFilename as string` | the old path of a renamed file; "" otherwise |

### `Hook`

A webhook of a repository.

| Field | Meaning |
|---|---|
| `id as int` | the hook id |
| `name as string` | `web` for a webhook |
| `url as string` | where it posts to |
| `events as list of string` | the events it fires on, e.g. `push` |
| `active as bool` | whether it fires |

### `Entry`

An entry of a directory in a repository.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `path as string` | the path from the repository root |
| `type as string` | `file`, `dir`, `symlink` or `submodule` |
| `size as int` | bytes; 0 for a directory |
| `sha as string` | the blob or tree SHA |

### `RateLimit`

The REST rate limit of the client's token, or of its address without one.

| Field | Meaning |
|---|---|
| `limit as int` | requests allowed per hour |
| `remaining as int` | requests left in this hour |
| `used as int` | requests made in this hour |
| `reset as int` | when it starts over, Unix seconds |

### `GithubError`

A failed request or a refused value. Every error of kind `"github"` is one, so its fields are safe to read once the kind matches.

| Field | Meaning |
|---|---|
| `kind as string` | always `"github"` (`ERROR_KIND`) |
| `message as string` | `github: ` and what failed, for a refused request `<verb> <path>: HTTP <status>: <reason>` |
| `status as int` | the HTTP status GitHub answered (401, 403, 404, 409, 422, 429, ...; 200 for a GraphQL error); 0 when the failure is a local check or no usable answer was read |

## Connecting

| Function | Returns | Does |
|---|---|---|
| `github.client(address)` | `Client` | github.com or an Enterprise Server, without a token; requests refuse plain http to another machine |
| `github.withPlainHttp(c)` | `Client` | allow plain http to another machine (an Enterprise Server on the LAN) |
| `github.withToken(c, token)` | `Client` | authenticate with a token |
| `github.withUserAgent(c, agent)` | `Client` | send another `User-Agent` |
| `github.withCaCert(c, pem)` | `Client` | trust a certificate |
| `github.withInsecure(c)` | `Client` | accept any certificate |
| `github.withTimeout(c, ms)` | `Client` | set the idle timeout |
| `github.withRetries(c, n)` | `Client` | retry GETs answered 5xx or rate limited with a stated wait |
| `github.call(c, method, path, body)` | `json.Value` | any REST endpoint; `body` is JSON text |
| `github.getAll(c, path)` | `list of json.Value` | every page of a list endpoint |
| `github.graphql(c, query, variables)` | `json.Value` | a GraphQL document; the reply's `data` |
| `github.currentUser(c)` | `User` | the token's account |
| `github.rateLimit(c)` | `RateLimit` | the REST rate limit left |

## Repositories

| Function | Returns | Does |
|---|---|---|
| `github.repository(c, repo)` | `Repository` | one repository |
| `github.repositories(c, owner)` | `list of Repository` | a user's or organization's public repositories |
| `github.myRepositories(c)` | `list of Repository` | the token's own and shared repositories |
| `github.createRepository(c, owner, name, description, isPrivate)` | `Repository` | an empty repository; owner `""` for the token's account |
| `github.deleteRepository(c, repo)` | | delete it, with no undo |
| `github.editRepository(c, repo, description, homepage)` | `Repository` | change them; `""` keeps |
| `github.setArchived(c, repo, archived)` | `Repository` | archive it or bring it back |
| `github.setDefaultBranch(c, repo, branch)` | `Repository` | change the default branch |
| `github.forkRepository(c, repo, organization, name)` | `Repository` | fork it; `""` for your account, the same name |
| `github.searchRepositories(c, query)` | `list of Repository` | GitHub's repository search, at most 1000 |
| `github.collaborators(c, repo)` | `list of User` | the collaborators |
| `github.addCollaborator(c, repo, name, permission)` | | `pull`, `triage`, `push`, `maintain` or `admin` |
| `github.removeCollaborator(c, repo, name)` | | remove one |
| `github.hooks(c, repo)` | `list of Hook` | the webhooks |
| `github.createHook(c, repo, url, secret, events)` | `Hook` | a webhook posting JSON |
| `github.deleteHook(c, repo, id)` | | delete one |
| `github.branches(c, repo)` | `list of Branch` | the branches |
| `github.tags(c, repo)` | `list of Tag` | the tags, without annotations |
| `github.createBranch(c, repo, name, from)` | `Branch` | branch off a ref; `""` for the default branch |
| `github.deleteBranch(c, repo, name)` | | delete a branch |
| `github.createTag(c, repo, name, target, message)` | `Tag` | tag a ref; `""` message for a lightweight tag |
| `github.deleteTag(c, repo, name)` | | delete a tag |
| `github.readFile(c, repo, path, ref, maxBytes)` | `bytes` | a file at a ref; `""` for the default branch; `maxBytes` at most `MAX_FILE_BYTES`, 0 for 64 MiB, negative for no limit |
| `github.writeFile(c, repo, path, data, message, branch)` | `string` | commit a file; the commit SHA |
| `github.deleteFile(c, repo, path, message, branch)` | `string` | delete a file; the commit SHA |
| `github.listDirectory(c, repo, path, ref)` | `list of Entry` | a directory's entries; `""` for the root |

## Issues and pull requests

| Function | Returns | Does |
|---|---|---|
| `github.issues(c, repo, state)` | `list of Issue` | issues, without pull requests |
| `github.searchIssues(c, query)` | `list of Issue` | GitHub's issue search, at most 1000 |
| `github.issue(c, repo, number)` | `Issue` | one issue |
| `github.createIssue(c, repo, title, body)` | `Issue` | open an issue |
| `github.closeIssue(c, repo, number)` | `Issue` | close an issue or pull request |
| `github.reopenIssue(c, repo, number)` | `Issue` | reopen one |
| `github.editIssue(c, repo, number, title, body)` | `Issue` | change title or text; `""` keeps |
| `github.setAssignees(c, repo, number, names)` | `Issue` | set who is assigned |
| `github.setMilestone(c, repo, number, milestone)` | `Issue` | put it in a milestone by number; 0 for none |
| `github.comments(c, repo, number)` | `list of Comment` | its comments, oldest first |
| `github.comment(c, repo, number, body)` | `Comment` | add a comment |
| `github.editComment(c, repo, id, body)` | `Comment` | change a comment |
| `github.deleteComment(c, repo, id)` | | delete a comment |
| `github.labels(c, repo)` | `list of Label` | the repository's labels |
| `github.createLabel(c, repo, name, color, description)` | `Label` | create a label |
| `github.deleteLabel(c, repo, name)` | | delete a label by name |
| `github.setIssueLabels(c, repo, number, names)` | `list of Label` | replace its labels |
| `github.addIssueLabels(c, repo, number, names)` | `list of Label` | add labels |
| `github.removeIssueLabel(c, repo, number, name)` | | take a label off |
| `github.milestones(c, repo, state)` | `list of Milestone` | the milestones |
| `github.createMilestone(c, repo, title, description, dueOn)` | `Milestone` | create one |
| `github.setMilestoneClosed(c, repo, number, closed)` | `Milestone` | close or reopen one |
| `github.deleteMilestone(c, repo, number)` | | delete one |
| `github.pullRequests(c, repo, state)` | `list of PullRequest` | pull requests |
| `github.pullRequest(c, repo, number)` | `PullRequest` | one pull request |
| `github.createPullRequest(c, repo, head, base, title, body, isDraft)` | `PullRequest` | open a pull request, a draft with `isDraft` |
| `github.mergePullRequest(c, repo, number, style, deleteBranch)` | | merge it |
| `github.editPullRequest(c, repo, number, title, body)` | `PullRequest` | change title or text; `""` keeps |
| `github.reviewPullRequest(c, repo, number, event, body)` | `Review` | `APPROVE`, `REQUEST_CHANGES` or `COMMENT` |
| `github.reviews(c, repo, number)` | `list of Review` | its reviews |
| `github.requestReviewers(c, repo, number, names)` | | ask users to review |
| `github.pullRequestFiles(c, repo, number)` | `list of ChangedFile` | the files it changes |

## Releases

| Function | Returns | Does |
|---|---|---|
| `github.releases(c, repo)` | `list of Release` | the releases, newest first |
| `github.release(c, repo, tag)` | `Release` | the release of a tag |
| `github.latestRelease(c, repo)` | `Release` | the one GitHub marks as the latest |
| `github.createRelease(c, repo, tag, target, name, body, isPrerelease)` | `Release` | publish a release |
| `github.editRelease(c, repo, id, name, body)` | `Release` | change title or notes; `""` keeps |
| `github.deleteRelease(c, repo, id)` | | delete it; the tag stays |
| `github.uploadAsset(c, repo, releaseId, name, contentType, data)` | `Asset` | attach a file; `contentType` "" for `application/octet-stream` |
| `github.downloadAsset(c, asset, maxBytes)` | `bytes` | download a file; the token stays on the API host |
| `github.deleteAsset(c, repo, assetId)` | | delete an attached file |

## Commits and CI

| Function | Returns | Does |
|---|---|---|
| `github.commits(c, repo, ref, path)` | `list of Commit` | commits from a ref; `path` narrows them |
| `github.commit(c, repo, sha)` | `Commit` | one commit |
| `github.setCommitStatus(c, repo, sha, state, context, description, targetUrl)` | `CommitStatus` | report a check on a commit |
| `github.commitStatuses(c, repo, ref)` | `list of CommitStatus` | every status set on it, newest first |
| `github.combinedStatus(c, repo, ref)` | `CombinedStatus` | the latest per check, and the worst |
| `github.checkRuns(c, repo, ref)` | `list of CheckRun` | the check runs, Actions jobs among them |
| `github.dispatchWorkflow(c, repo, workflow, ref, inputs)` | `int` | run a workflow with at most `MAX_WORKFLOW_INPUTS` inputs; the run id, or 0 |
| `github.workflowRun(c, repo, id)` | `WorkflowRun` | one workflow run |
| `github.secrets(c, repo)` | `list of string` | the Actions secrets' names |
| `github.setSecret(c, repo, name, value)` | | seal and create or replace one |
| `github.deleteSecret(c, repo, name)` | | delete one |
| `github.variables(c, repo)` | `map of string to string` | the Actions variables |
| `github.setVariable(c, repo, name, value)` | | create or replace one |
| `github.deleteVariable(c, repo, name)` | | delete one |
