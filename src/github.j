# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A client for the GitHub REST API (version `2022-11-28`) and its GraphQL
 * endpoint, for github.com and GitHub Enterprise Server.
 *
 * A thin client: `call` reaches any REST endpoint, `getAll` follows the
 * `Link` pages of a list and `graphql` runs a GraphQL document. Typed verbs
 * cover the daily work: repositories, issues and comments, pull requests,
 * releases and their assets, branches, tags, files, commit statuses and
 * Actions.
 *
 * A `Client` authenticates with a token (`withToken`). Every failure is a
 * `GithubError` (kind `"github"`) carrying the HTTP `status`, except that a
 * listing past `MAX_PAGES` pages or a reply over its size cap is kind
 * `"limit"`, a deadline is kind `"timeout"`, and a connection closed under
 * a request is kind `"closed"`.
 *
 * `setSecret` seals an Actions secret with the repository's public key
 * (libsodium's sealed box, `crypto.wrap("nacl-sealedbox", ...)`) before it
 * leaves the machine; GitHub never sees it in the clear.
 *
 * @module github
 * @see https://docs.github.com/en/rest
 * @example
 *   def c as github.Client init github.withToken(github.client("github.com"), $token);
 *   for (def i in github.issues($c, "octocat/hello-world", "open")) {
 *       io.printf("#%d %s\n", $i.number, $i.title);
 *   }
 */
use convert;
use crypto;
use encoding;
use json;
use lists;
use maps;
use regex;
use strings;
use time;
import "graphql.j" as gql;
import "http.j" as http;
import "uri.j" as uri;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "github";

/** The REST API version every request asks for (`X-GitHub-Api-Version`). */
export def const API_VERSION as string init "2022-11-28";

/** The entries `getAll` and the list verbs ask for per page, GitHub's maximum. */
export def const PAGE_SIZE as int init 100;

/** The most pages a list follows before it refuses. */
export def const MAX_PAGES as int init 1000;

/** The longest wait, in milliseconds, a retried GET sleeps through. */
export def const MAX_RETRY_WAIT_MS as int init 60000;

/** The longest Actions secret value in bytes, GitHub's limit (48 KB). */
export def const MAX_SECRET_BYTES as int init 49152;

/** The `User-Agent` a client sends until `withUserAgent` changes it. */
export def const USER_AGENT as string init "jennifer-deckyard-github";

/** The ways `mergePullRequest` can merge. */
export def const MERGE_STYLES as list of string init ["merge", "squash", "rebase"];

/** The largest `maxBytes` `readFile` takes: GitHub serves raw files up to 100 MB. */
export def const MAX_FILE_BYTES as int init 104857600;

/** The most inputs `dispatchWorkflow` sends, GitHub's limit for a dispatch. */
export def const MAX_WORKFLOW_INPUTS as int init 25;

/**
 * A connection to github.com or a GitHub Enterprise Server.
 *
 * @field url {string} the REST base, `https://api.github.com` or `https://host/api/v3`
 * @field uploadUrl {string} where release assets go, `https://uploads.github.com` or `https://host/api/uploads`
 * @field graphqlUrl {string} the GraphQL endpoint
 * @field token {string} the token; "" for anonymous reads
 * @field userAgent {string} the `User-Agent` header
 * @field tls {http.TlsOptions} certificate checking
 * @field timeoutMs {int} the idle timeout of each request; 0 for 30 s
 * @field retries {int} retries of a GET answered 5xx or rate limited
 * @field allowPlainHttp {bool} whether plain `http` to another machine is
 *   allowed (the token then crosses the network in clear)
 */
export def struct Client {
    url as string,
    uploadUrl as string,
    graphqlUrl as string,
    token as string,
    userAgent as string,
    tls as http.TlsOptions,
    timeoutMs as int,
    retries as int,
    allowPlainHttp as bool
};

/**
 * An account.
 *
 * @field id {int} the account id
 * @field login {string} the user name
 * @field name {string} the display name
 * @field email {string} the public e-mail address
 * @field isAdmin {bool} whether it administers the server (`site_admin`)
 */
export def struct User {
    id as int,
    login as string,
    name as string,
    email as string,
    isAdmin as bool
};

/**
 * A repository.
 *
 * @field id {int} the repository id
 * @field owner {string} the owning user or organization
 * @field name {string} the name
 * @field fullName {string} `owner/name`
 * @field description {string} the description
 * @field isPrivate {bool} whether it is private
 * @field isFork {bool} whether it is a fork
 * @field isArchived {bool} whether it is archived
 * @field defaultBranch {string} e.g. `main`
 * @field htmlUrl {string} its page
 * @field cloneUrl {string} the HTTPS clone URL
 * @field sshUrl {string} the SSH clone URL
 * @field stars {int} the star count
 * @field openIssues {int} open issues and pull requests
 * @field updated {string} last update, RFC 3339
 */
export def struct Repository {
    id as int,
    owner as string,
    name as string,
    fullName as string,
    description as string,
    isPrivate as bool,
    isFork as bool,
    isArchived as bool,
    defaultBranch as string,
    htmlUrl as string,
    cloneUrl as string,
    sshUrl as string,
    stars as int,
    openIssues as int,
    updated as string
};

/**
 * An issue.
 *
 * @field number {int} the number within the repository
 * @field title {string} the title
 * @field body {string} the text, Markdown
 * @field state {string} `open` or `closed`
 * @field author {string} who opened it
 * @field labels {list of string} label names
 * @field assignees {list of string} assigned user names
 * @field comments {int} the comment count
 * @field isPull {bool} whether it is a pull request
 * @field created {string} RFC 3339
 * @field updated {string} RFC 3339
 * @field closed {string} RFC 3339; "" while open
 * @field htmlUrl {string} its page
 */
export def struct Issue {
    number as int,
    title as string,
    body as string,
    state as string,
    author as string,
    labels as list of string,
    assignees as list of string,
    comments as int,
    isPull as bool,
    created as string,
    updated as string,
    closed as string,
    htmlUrl as string
};

/**
 * A comment on an issue or pull request.
 *
 * @field id {int} the comment id
 * @field author {string} who wrote it
 * @field body {string} the text, Markdown
 * @field created {string} RFC 3339
 * @field htmlUrl {string} its place on the page
 */
export def struct Comment {
    id as int,
    author as string,
    body as string,
    created as string,
    htmlUrl as string
};

/**
 * A pull request.
 *
 * @field number {int} the number within the repository
 * @field title {string} the title
 * @field body {string} the text, Markdown
 * @field state {string} `open` or `closed`
 * @field author {string} who opened it
 * @field head {string} the branch with the changes
 * @field base {string} the branch it merges into
 * @field headSha {string} the commit at the head
 * @field isDraft {bool} whether it is a draft
 * @field mergeable {bool} whether GitHub can merge it; false while GitHub
 *   is still computing it, and in a listing
 * @field merged {bool} whether it is merged
 * @field mergeSha {string} the merge commit, or the test merge commit of an
 *   open one; "" when there is none
 * @field htmlUrl {string} its page
 */
export def struct PullRequest {
    number as int,
    title as string,
    body as string,
    state as string,
    author as string,
    head as string,
    base as string,
    headSha as string,
    isDraft as bool,
    mergeable as bool,
    merged as bool,
    mergeSha as string,
    htmlUrl as string
};

/**
 * A file attached to a release.
 *
 * @field id {int} the asset id
 * @field name {string} the file name
 * @field contentType {string} the media type it was uploaded with
 * @field size {int} bytes
 * @field downloads {int} the download count
 * @field downloadUrl {string} the browser download link
 * @field apiUrl {string} the asset's API URL, which `downloadAsset` reads
 */
export def struct Asset {
    id as int,
    name as string,
    contentType as string,
    size as int,
    downloads as int,
    downloadUrl as string,
    apiUrl as string
};

/**
 * A release.
 *
 * @field id {int} the release id
 * @field tag {string} the tag it is for
 * @field name {string} the title
 * @field body {string} the notes, Markdown
 * @field isDraft {bool} whether it is a draft
 * @field isPrerelease {bool} whether it is a pre-release
 * @field created {string} RFC 3339
 * @field published {string} RFC 3339; "" for a draft
 * @field htmlUrl {string} its page
 * @field assets {list of Asset} the attached files
 */
export def struct Release {
    id as int,
    tag as string,
    name as string,
    body as string,
    isDraft as bool,
    isPrerelease as bool,
    created as string,
    published as string,
    htmlUrl as string,
    assets as list of Asset
};

/**
 * A branch.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field isProtected {bool} whether a protection rule covers it
 */
export def struct Branch {
    name as string,
    sha as string,
    isProtected as bool
};

/**
 * A tag.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field message {string} the annotation `createTag` wrote; "" in a listing,
 *   which does not carry it
 */
export def struct Tag {
    name as string,
    sha as string,
    message as string
};

/**
 * The status a CI system set on a commit.
 *
 * @field context {string} which check it is, e.g. `ci/build`
 * @field state {string} `pending`, `success`, `error` or `failure`
 * @field description {string} a short text
 * @field targetUrl {string} where the details are
 * @field creator {string} who set it
 * @field created {string} RFC 3339
 */
export def struct CommitStatus {
    context as string,
    state as string,
    description as string,
    targetUrl as string,
    creator as string,
    created as string
};

/**
 * The statuses of a commit, combined.
 *
 * @field state {string} `failure`, `pending` or `success`; `pending` when
 *   there are none
 * @field statuses {list of CommitStatus} the latest status per context
 */
export def struct CombinedStatus {
    state as string,
    statuses as list of CommitStatus
};

/**
 * A check run on a commit, as GitHub Actions and other apps report them.
 *
 * @field id {int} the check run id
 * @field name {string} e.g. `build`
 * @field status {string} `queued`, `in_progress`, `completed`, `waiting`,
 *   `requested` or `pending`
 * @field conclusion {string} `success`, `failure`, `neutral`, `cancelled`,
 *   `skipped`, `timed_out` or `action_required`; "" until completed
 * @field htmlUrl {string} its page
 * @field started {string} RFC 3339
 * @field completed {string} RFC 3339; "" until completed
 */
export def struct CheckRun {
    id as int,
    name as string,
    status as string,
    conclusion as string,
    htmlUrl as string,
    started as string,
    completed as string
};

/**
 * A run of an Actions workflow.
 *
 * @field id {int} the run id
 * @field name {string} the workflow's name
 * @field event {string} what started it, e.g. `push`, `workflow_dispatch`
 * @field status {string} e.g. `queued`, `in_progress`, `completed`
 * @field conclusion {string} e.g. `success`, `failure`; "" until completed
 * @field headBranch {string} the branch it ran on
 * @field headSha {string} the commit it ran on
 * @field htmlUrl {string} its page
 * @field created {string} RFC 3339
 */
export def struct WorkflowRun {
    id as int,
    name as string,
    event as string,
    status as string,
    conclusion as string,
    headBranch as string,
    headSha as string,
    htmlUrl as string,
    created as string
};

/**
 * A commit.
 *
 * @field sha {string} the commit SHA
 * @field message {string} the commit message
 * @field author {string} the author's name, as Git records it
 * @field authorEmail {string} the author's e-mail address
 * @field date {string} the author date, RFC 3339
 * @field htmlUrl {string} its page
 */
export def struct Commit {
    sha as string,
    message as string,
    author as string,
    authorEmail as string,
    date as string,
    htmlUrl as string
};

/**
 * A label of a repository.
 *
 * @field id {int} the label id
 * @field name {string} the name, e.g. `bug`
 * @field color {string} the colour, e.g. `#d73a4a`
 * @field description {string} the description
 * @field isDefault {bool} whether GitHub created it with the repository
 */
export def struct Label {
    id as int,
    name as string,
    color as string,
    description as string,
    isDefault as bool
};

/**
 * A milestone of a repository. GitHub addresses it by its `number`.
 *
 * @field number {int} the number within the repository
 * @field title {string} the title
 * @field description {string} the description
 * @field state {string} `open` or `closed`
 * @field dueOn {string} RFC 3339; "" without a due date
 * @field openIssues {int} open issues in it
 * @field closedIssues {int} closed issues in it
 */
export def struct Milestone {
    number as int,
    title as string,
    description as string,
    state as string,
    dueOn as string,
    openIssues as int,
    closedIssues as int
};

/**
 * A review of a pull request.
 *
 * @field id {int} the review id
 * @field author {string} who reviewed
 * @field state {string} `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`,
 *   `DISMISSED` or `PENDING`
 * @field body {string} the text, Markdown
 * @field commitId {string} the commit it reviewed
 * @field submitted {string} RFC 3339
 */
export def struct Review {
    id as int,
    author as string,
    state as string,
    body as string,
    commitId as string,
    submitted as string
};

/**
 * A file a pull request changes.
 *
 * @field filename {string} the path
 * @field status {string} `added`, `removed`, `modified`, `renamed`,
 *   `copied`, `changed` or `unchanged`
 * @field additions {int} lines added
 * @field deletions {int} lines deleted
 * @field previousFilename {string} the old path of a renamed file; ""
 *   otherwise
 */
export def struct ChangedFile {
    filename as string,
    status as string,
    additions as int,
    deletions as int,
    previousFilename as string
};

/**
 * A webhook of a repository.
 *
 * @field id {int} the hook id
 * @field name {string} `web` for a webhook
 * @field url {string} where it posts to
 * @field events {list of string} the events it fires on, e.g. `push`
 * @field active {bool} whether it fires
 */
export def struct Hook {
    id as int,
    name as string,
    url as string,
    events as list of string,
    active as bool
};

/**
 * An entry of a directory in a repository.
 *
 * @field name {string} the name
 * @field path {string} the path from the repository root
 * @field type {string} `file`, `dir`, `symlink` or `submodule`
 * @field size {int} bytes; 0 for a directory
 * @field sha {string} the blob or tree SHA
 */
export def struct Entry {
    name as string,
    path as string,
    type as string,
    size as int,
    sha as string
};

/**
 * The REST rate limit of the client's token, or of its address without one.
 *
 * @field limit {int} requests allowed per hour
 * @field remaining {int} requests left in this hour
 * @field used {int} requests made in this hour
 * @field reset {int} when it starts over, Unix seconds
 */
export def struct RateLimit {
    limit as int,
    remaining as int,
    used as int,
    reset as int
};

/**
 * A failed request or a refused value. Every error of kind `"github"` is one,
 * so its fields are safe to read once the kind matches.
 *
 * @field kind {string} always `"github"` (`ERROR_KIND`)
 * @field message {string} `github: ` and what failed, for a refused request `<verb> <path>: HTTP <status>: <reason>`
 * @field status {int} the HTTP status GitHub answered (401, 403, 404, 409, 422, 429, ...; 200 for a GraphQL error); 0 when no answer was read or the failure is a local check
 */
export def struct GithubError {
    kind as string,
    message as string,
    status as int
};

# An owner or repository name as GitHub allows it.
def const NAME_PATTERN as string init '^[A-Za-z0-9_.-]+$';

# How much of a string an error message repeats.
def const SHOWN as int init 60;

# How much of the server's reason for a refusal an error message repeats.
def const REASON as int init 200;

# The idle timeout a `timeoutMs` of 0 stands for, as `http.send` has it.
def const DEFAULT_TIMEOUT_MS as int init 30000;

# The first backoff of a retried GET answered 5xx, doubled per attempt.
def const BACKOFF_MS as int init 1000;

# The redirects `downloadAsset` follows, none of them with the token.
def const MAX_REDIRECTS as int init 5;

# The hosts plain http is allowed to without `withPlainHttp`: this machine.
def const LOOPBACK as list of string init ["127.0.0.1", "localhost", "[::1]"];

# A `Link` header entry: `<url>; rel="next"`.
def const LINK_PATTERN as string init '<([^>]*)>\s*;\s*rel="([^"]*)"';

func fail(message as string) {
    failStatus($message, 0);
}

# failStatus throws the GithubError of a refused request, with its status.
func failStatus(message as string, status as int) {
    throw GithubError{kind: ERROR_KIND, message: "github: " + $message, status: $status};
}

# failTransport throws the error of a request that got no usable answer: a
# reached cap stays kind "limit", a deadline "timeout" and a connection closed
# under the call "closed", with the request in front of the cause; a cancelled
# task is passed on as it is; anything else is a GithubError with status 0.
func failTransport(what as string, e as Error) {
    if ($e.kind == "cancelled") {
        throw $e;
    }
    if ($e.kind == "limit" or $e.kind == "timeout" or $e.kind == "closed") {
        throw Error{kind: $e.kind, message: "github: " + $what + ": " + $e.message};
    }
    fail($what + ": " + $e.message);
}

/**
 * A string fit for an error message: cut to `most` characters, with
 * anything but printable ASCII as `?`, so a message stays one line and
 * carries no terminal escape into a log.
 *
 * @param text {string} a caller's or the server's string
 * @param most {int} the characters kept
 * @return {string} the text
 */
func plain(text as string, most as int) {
    def cut as string init $text;
    def more as string init "";
    if (len($text) > $most) {
        $cut = strings.substring($text, 0, $most);
        $more = "...";
    }
    return regex.replace("[^ -~]", $cut, "?") + $more;
}

/**
 * A string as an error message quotes it: `plain`, cut to `SHOWN`.
 *
 * @param text {string} a caller's or the server's string
 * @return {string} the text in double quotes
 */
func shown(text as string) {
    return "\"" + plain($text, SHOWN) + "\"";
}

/**
 * A URL as an error message shows it: without its query, which on a
 * download link carries a signature.
 *
 * @param url {string} the URL
 * @return {string} the URL up to its `?`
 */
func withoutQuery(url as string) {
    if (strings.contains($url, "?")) {
        return strings.substring($url, 0, strings.indexOf($url, "?"));
    }
    return $url;
}

/**
 * A client for github.com or a GitHub Enterprise Server, without a token.
 *
 * `github.com` and `api.github.com` mean github.com; any other host is a
 * GitHub Enterprise Server, reached at `/api/v3` (REST), `/api/graphql` and
 * `/api/uploads`. Plain `http://` to another machine than this one
 * (`127.0.0.1`, `::1`, `localhost`) is refused when a request is sent: add
 * `withPlainHttp` for such a server.
 *
 * @param address {string} `github.com`, a host name, `host:port`, or
 *   `https://host`; a trailing `/api/v3` is dropped
 * @return {Client} the client; full certificate checking
 * @throws {GithubError} kind `"github"` when the address is empty, has
 *   another path, or names github.com over plain `http://`
 * @example
 *   def c as github.Client init github.client("github.com");
 *   $c = github.client("https://github.example.com");     # Enterprise Server
 *   $c = github.withPlainHttp(github.client("http://ghes.lan"));
 */
export func client(address as string) {
    def text as string init strings.trim($address);
    if ($text == "") {
        fail("the address is empty");
    }
    def scheme as string init "https";
    def rest as string init $text;
    if (strings.contains($rest, "://")) {
        $scheme = strings.lower(strings.substring($rest, 0, strings.indexOf($rest, "://")));
        $rest = strings.substring($rest, strings.indexOf($rest, "://") + 3, len($rest));
        if ($scheme != "https" and $scheme != "http") {
            fail("an address is https:// or http://, got " + shown($address));
        }
    }
    while (strings.endsWith($rest, "/")) {
        $rest = strings.substring($rest, 0, len($rest) - 1);
    }
    if (strings.endsWith($rest, "/api/v3")) {
        $rest = strings.substring($rest, 0, len($rest) - len("/api/v3"));
    }
    if (not regex.matches('^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$', $rest)) {
        fail("an address is a host, host:port or https://host, got " + shown($address));
    }
    def host as string init strings.lower($rest);
    def c as Client;
    $c.userAgent = USER_AGENT;
    if ($host == "github.com" or $host == "api.github.com") {
        if ($scheme != "https") {
            fail("github.com is reached over https://, got " + shown($address));
        }
        $c.url = "https://api.github.com";
        $c.uploadUrl = "https://uploads.github.com";
        $c.graphqlUrl = "https://api.github.com/graphql";
        return $c;
    }
    def base as string init $scheme + "://" + $host;
    $c.url = $base + "/api/v3";
    $c.uploadUrl = $base + "/api/uploads";
    $c.graphqlUrl = $base + "/api/graphql";
    return $c;
}

/**
 * The client allowed to use plain `http` to another machine, such as an
 * Enterprise Server on the LAN without TLS. The token crosses the network
 * in clear.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 * @example
 *   def c as github.Client init github.withPlainHttp(github.client("http://ghes.lan"));
 */
export func withPlainHttp(c as Client) {
    $c.allowPlainHttp = true;
    return $c;
}

/**
 * Refuse plain http to another machine unless `withPlainHttp` allowed it.
 * Run before every request, so a refused client sends nothing, the token
 * included.
 *
 * @param c {Client} the client
 */
func checkPlain(c as Client) {
    if (strings.startsWith($c.url, "http://") and not $c.allowPlainHttp) {
        def m as regex.Match init regex.find('^http://(\[[0-9A-Fa-f:.]+\]|[^:/]+)', $c.url);
        def host as string init strings.lower($m.groups[0]);
        if (not lists.contains(LOOPBACK, $host)) {
            fail("plain http to " + shown($host) +
                " would send the token in clear: use https, or withPlainHttp");
        }
    }
}

/**
 * Authenticate with a token: a fine-grained or classic personal access
 * token, a GitHub App installation token, or Actions' `GITHUB_TOKEN`. Give
 * it only the permissions the program needs.
 *
 * @param c {Client} the client
 * @param token {string} the token
 * @return {Client} the changed copy
 * @throws {GithubError} kind `"github"` when the token holds spaces or
 *   control characters
 */
export func withToken(c as Client, token as string) {
    if (regex.matches('[\s\x00-\x1f\x7f]', $token)) {
        fail("a token holds no spaces or control characters");
    }
    $c.token = $token;
    return $c;
}

/**
 * Send another `User-Agent`. GitHub asks for the name of the application
 * or of its owner, and refuses a request without one.
 *
 * @param c {Client} the client
 * @param agent {string} e.g. `my-release-bot`
 * @return {Client} the changed copy
 * @throws {GithubError} kind `"github"` when it is empty or holds control
 *   characters
 */
export func withUserAgent(c as Client, agent as string) {
    if (strings.trim($agent) == "" or regex.matches('[\x00-\x1f\x7f]', $agent)) {
        fail("a user agent is not empty and holds no control characters");
    }
    $c.userAgent = $agent;
    return $c;
}

/**
 * Trust a certificate (PEM) in addition to the system's, for an Enterprise
 * Server with a private CA or a self-signed certificate.
 *
 * @param c {Client} the client
 * @param pem {bytes} the certificate
 * @return {Client} the changed copy
 */
export func withCaCert(c as Client, pem as bytes) {
    $c.tls.caCert = $pem;
    $c.tls.skipVerify = false;
    return $c;
}

/**
 * Accept any certificate. The connection is still encrypted but no longer
 * authenticated; prefer `withCaCert`.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withInsecure(c as Client) {
    $c.tls.skipVerify = true;
    return $c;
}

/**
 * Set the idle timeout of each request.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the default, 30 s
 * @return {Client} the changed copy
 * @throws {GithubError} kind `"github"` when it is negative
 */
export func withTimeout(c as Client, ms as int) {
    if ($ms < 0) {
        fail("a timeout is 0 or more milliseconds, got " + convert.toString($ms));
    }
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * Retry a GET answered 5xx, or rate limited with a wait GitHub states
 * (`Retry-After`, or `X-RateLimit-Reset` once `X-RateLimit-Remaining` is 0)
 * of at most `MAX_RETRY_WAIT_MS`. A rate limit without a stated wait, or a
 * longer one, fails at once. A 5xx waits 1 s, doubled per attempt. Writes
 * are never retried: they need not be idempotent.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 for none
 * @return {Client} the changed copy
 * @throws {GithubError} kind `"github"` when it is negative
 */
export func withRetries(c as Client, n as int) {
    if ($n < 0) {
        fail("retries are 0 or more, got " + convert.toString($n));
    }
    $c.retries = $n;
    return $c;
}

/**
 * Refuse an API path that would not address what it says.
 *
 * @param path {string} the path under the REST base, query string allowed
 */
func ensurePath(path as string) {
    if (not strings.startsWith($path, "/")) {
        fail("an API path starts with /, got " + shown($path));
    }
    def route as string init $path;
    if (strings.contains($route, "?")) {
        $route = strings.substring($route, 0, strings.indexOf($route, "?"));
    }
    if (strings.contains($route, "//") or strings.contains($route, "#") or
        regex.matches('[\x00-\x20\x7f]', $path)) {
        fail("an API path holds no //, # or spaces: " + shown($path));
    }
    for (def segment in strings.split($route, "/")) {
        if ($segment == "." or $segment == "..") {
            fail("an API path has no . or .. segments: " + shown($path));
        }
    }
}

/**
 * The `owner/name` of a repository, checked.
 *
 * @param repo {string} `owner/name`
 * @return {string} `/repos/owner/name`
 */
func repoPath(repo as string) {
    def parts as list of string init strings.split($repo, "/");
    if (len($parts) != 2) {
        fail("a repository is owner/name, got " + shown($repo));
    }
    for (def part in $parts) {
        if (not regex.matches(NAME_PATTERN, $part) or $part == "." or $part == "..") {
            fail("a repository is owner/name, got " + shown($repo));
        }
    }
    return "/repos/" + $repo;
}

/**
 * An owner or user name, checked.
 *
 * @param owner {string} a user or organization
 * @return {string} the name
 */
func checkOwner(owner as string) {
    if (not regex.matches(NAME_PATTERN, $owner) or $owner == "." or $owner == "..") {
        fail("an owner is a user or organization name, got " + shown($owner));
    }
    return $owner;
}

/**
 * A ref, tag or file path for a URL: each segment percent-encoded.
 *
 * @param text {string} e.g. `docs/a b.md` or `release/1.0`
 * @param what {string} what it is, for the error message
 * @return {string} the encoded path
 */
func segments(text as string, what as string) {
    if ($text == "" or regex.matches('[\x00-\x1f\x7f]', $text)) {
        fail("a " + $what + " is not empty and holds no control characters, got " + shown($text));
    }
    def out as list of string init [];
    for (def part in strings.split($text, "/")) {
        if ($part == "" or $part == "." or $part == "..") {
            fail("a " + $what + " has no empty, . or .. segments, got " + shown($text));
        }
        $out[] = uri.encode($part);
    }
    return strings.join($out, "/");
}

/**
 * A ref or name that goes into a URL as one segment, checked as `segments`
 * checks it but not encoded: the caller encodes it whole.
 *
 * @param text {string} the ref or name
 * @param what {string} what it is, for the error message
 * @return {string} the text as given
 */
func checked(text as string, what as string) {
    segments($text, $what);
    return $text;
}

/**
 * The headers every REST request carries: the media type, the API version,
 * the user agent and the token.
 *
 * @param c {Client} the client
 * @return {map of string to string} the headers
 */
func apiHeaders(c as Client) {
    def headers as map of string to string init {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": $c.userAgent
    };
    if ($c.token != "") {
        $headers["Authorization"] = "Bearer " + $c.token;
    }
    return $headers;
}

/**
 * The idle timeout for the `http` calls that take it directly, where 0
 * would mean no timeout at all.
 *
 * @param c {Client} the client
 * @return {int} milliseconds
 */
func idleMs(c as Client) {
    if ($c.timeoutMs == 0) {
        return DEFAULT_TIMEOUT_MS;
    }
    return $c.timeoutMs;
}

/**
 * A response header, by its lower-case name.
 *
 * @param headers {map of string to string} the headers, keys lower-cased
 * @param name {string} the lower-case name
 * @return {string} the value, trimmed; "" when absent
 */
func headerOf(headers as map of string to string, name as string) {
    if (maps.has($headers, $name)) {
        return strings.trim($headers[$name]);
    }
    return "";
}

/**
 * A header's value as seconds.
 *
 * @param text {string} the value
 * @return {int} the number; -1 when it is not a plain number of at most ten digits
 */
func secondsOf(text as string) {
    if (not regex.matches('^[0-9]{1,10}$', $text)) {
        return -1;
    }
    return convert.toInt($text);
}

/**
 * Whether a refusal is GitHub's rate limit: a 429, or a 403 with no
 * requests left or a `Retry-After`.
 *
 * @param status {int} the HTTP status
 * @param headers {map of string to string} the headers, keys lower-cased
 * @return {bool} whether it is a rate limit
 */
func isRateLimited(status as int, headers as map of string to string) {
    if ($status == 429) {
        return true;
    }
    return $status == 403 and
        (headerOf($headers, "x-ratelimit-remaining") == "0" or
        headerOf($headers, "retry-after") != "");
}

/**
 * How long GitHub asks a rate-limited caller to wait.
 *
 * @param headers {map of string to string} the headers, keys lower-cased
 * @param now {int} the time, Unix seconds
 * @return {int} milliseconds; -1 when GitHub states no wait
 */
func rateWaitMs(headers as map of string to string, now as int) {
    def after as int init secondsOf(headerOf($headers, "retry-after"));
    if ($after >= 0) {
        return $after * 1000;
    }
    def reset as int init secondsOf(headerOf($headers, "x-ratelimit-reset"));
    if (headerOf($headers, "x-ratelimit-remaining") == "0" and $reset >= 0) {
        if ($reset < $now) {
            return 1000;
        }
        return ($reset - $now + 1) * 1000;
    }
    return -1;
}

/**
 * How long to wait before retrying a GET.
 *
 * @param status {int} the HTTP status
 * @param headers {map of string to string} the headers, keys lower-cased
 * @param attempt {int} the retries made so far
 * @param now {int} the time, Unix seconds
 * @return {int} milliseconds; -1 when it is not to be retried
 */
func retryWaitMs(status as int, headers as map of string to string, attempt as int, now as int) {
    def wait as int init -1;
    if (isRateLimited($status, $headers)) {
        $wait = rateWaitMs($headers, $now);
    } elseif ($status >= 500 and $status <= 599) {
        $wait = BACKOFF_MS;
        def k as int init 0;
        while ($k < $attempt and $wait < MAX_RETRY_WAIT_MS) {
            $wait = $wait * 2;
            $k = $k + 1;
        }
        def after as int init secondsOf(headerOf($headers, "retry-after"));
        if ($after * 1000 > $wait) {
            $wait = $after * 1000;
        }
    }
    if ($wait > MAX_RETRY_WAIT_MS) {
        return -1;
    }
    return $wait;
}

/**
 * Explain a refused request: GitHub's `message`, the `errors` of a
 * validation failure, cut to `REASON` characters of printable ASCII, and
 * for a rate limit when it ends.
 *
 * @param status {int} the HTTP status
 * @param statusText {string} the reason phrase
 * @param headers {map of string to string} the headers, keys lower-cased
 * @param body {string} the body
 * @return {string} `HTTP <status>: <reason>`
 */
func failureText(
    status as int,
    statusText as string,
    headers as map of string to string,
    body as string) {
    def text as string init "HTTP " + convert.toString($status);
    def reason as string init strings.trim($statusText);
    def doc as json.Value init json.decode("null");
    try {
        $doc = json.decode($body);
    } catch (e) {
        $doc = json.decode("null");
    }
    if (json.typeOf($doc) == "map") {
        def said as string init strings.trim(field($doc, "/message"));
        if ($said != "") {
            $reason = $said;
        }
        def extra as list of string init [];
        for (def p in items($doc, "/errors")) {
            def item as string init strings.trim(field($doc, $p + "/message"));
            if ($item == "" and kindAt($doc, $p) == "map") {
                $item = strings.trim(field($doc, $p + "/field") + " " + field($doc, $p + "/code"));
            } elseif ($item == "") {
                $item = strings.trim(field($doc, $p));
            }
            if ($item != "") {
                $extra[] = $item;
            }
        }
        if (len($extra) > 0) {
            $reason = $reason + " (" + strings.join($extra, "; ") + ")";
        }
    }
    if ($reason != "") {
        $text = $text + ": " + plain($reason, REASON);
    }
    if (isRateLimited($status, $headers)) {
        def reset as int init secondsOf(headerOf($headers, "x-ratelimit-reset"));
        def after as int init secondsOf(headerOf($headers, "retry-after"));
        if ($after >= 0) {
            $text = $text + " [rate limited; retry after " + convert.toString($after) + " s]";
        } elseif (headerOf($headers, "x-ratelimit-remaining") == "0" and $reset >= 0) {
            $text = $text + " [rate limit exhausted; resets at " + time.iso(time.fromUnix($reset)) +
                "]";
        } else {
            $text = $text + " [rate limited]";
        }
    }
    return $text;
}

/**
 * Send a request to the REST API and return the response, a non-2xx
 * refused. A GET follows up to three redirects (a renamed repository; the
 * token is dropped on another origin) and is retried as `withRetries` says.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param path {string} the path under the REST base
 * @param body {string} JSON, or "" for none
 * @return {http.Response} the response
 */
func exchange(c as Client, method as string, path as string, body as string) {
    def verb as string init strings.upper($method);
    if (not lists.contains(["GET", "POST", "PUT", "PATCH", "DELETE"], $verb)) {
        fail("unsupported method " + shown($method));
    }
    ensurePath($path);
    checkPlain($c);
    def headers as map of string to string init apiHeaders($c);
    if ($body != "") {
        $headers["Content-Type"] = "application/json";
    }
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    if ($verb == "GET") {
        $o.maxRedirects = 3;
    }
    def attempt as int init 0;
    while (true) {
        def r as http.Response;
        try {
            $r = http.send($verb, $c.url + $path, $headers, $body, $o);
        } catch (e) {
            failTransport($verb + " " + $path, $e);
        }
        if ($r.status >= 200 and $r.status < 300) {
            return $r;
        }
        def wait as int init -1;
        if ($verb == "GET" and $attempt < $c.retries) {
            $wait = retryWaitMs($r.status, $r.headers, $attempt, time.unix(time.utc()));
        }
        if ($wait < 0) {
            failStatus(
                $verb + " " + $path + ": " +
                    failureText($r.status, $r.statusText, $r.headers, $r.body),
                $r.status);
        }
        time.sleep(time.fromMilliseconds($wait));
        $attempt = $attempt + 1;
    }
    return http.Response{status: 0, statusText: "", headers: {}, body: ""};
}

/**
 * Decode a reply body.
 *
 * @param body {string} the body
 * @param what {string} the request, for the error message
 * @return {json.Value} the document; JSON `null` for an empty body
 */
func decoded(body as string, what as string) {
    if (strings.trim($body) == "") {
        return json.decode("null");
    }
    try {
        return json.decode($body);
    } catch (e) {
        fail($what + ": the reply is not JSON");
    }
    return json.decode("null");
}

/**
 * Call any REST endpoint.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PUT`, `PATCH` or `DELETE`
 * @param path {string} the path under the REST base, query string included,
 *   e.g. `/repos/octocat/hello-world/labels?per_page=10`
 * @param body {string} the JSON body; "" for none
 * @return {json.Value} the reply; JSON `null` when it is empty
 * @throws {GithubError} kind `"github"` on a bad path, a network failure or
 *   a reply that is not 2xx; the message names the status and GitHub's reason
 * @example
 *   def labels as json.Value init github.call($c, "GET", "/repos/me/app/labels", "");
 */
export func call(c as Client, method as string, path as string, body as string) {
    def r as http.Response init exchange($c, $method, $path, $body);
    return decoded($r.body, strings.upper($method) + " " + $path);
}

/**
 * The pages of a list.
 *
 * @field first {json.Value} the first reply
 * @field entries {list of json.Value} the entries of every page
 */
def struct Paged {
    first as json.Value,
    entries as list of json.Value
};

/**
 * Where a reply keeps its entries: the reply itself when it is a list, or
 * the one member of an object that is a list (`items` of a search,
 * `variables`, `check_runs`, `statuses`, ...).
 *
 * @param doc {json.Value} the reply
 * @param what {string} the request, for the error message
 * @return {string} the list's pointer; "" for the root
 */
func listAt(doc as json.Value, what as string) {
    def kind as string init kindAt($doc, "");
    if ($kind == "list") {
        return "";
    }
    if ($kind == "map") {
        def found as list of string init [];
        for (def key in json.keys($doc)) {
            def p as string init "/" + strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
            if (kindAt($doc, $p) == "list") {
                $found[] = $p;
            }
        }
        if (len($found) == 1) {
            return $found[0];
        }
    }
    fail($what + ": the reply is neither a list nor an object holding one list");
    return "";
}

/**
 * The path of the next page, from the `Link` header.
 *
 * @param c {Client} the client
 * @param link {string} the header; "" when absent
 * @param what {string} the request, for the error message
 * @return {string} the path under the REST base; "" on the last page
 */
func nextPath(c as Client, link as string, what as string) {
    if ($link == "") {
        return "";
    }
    for (def m in regex.findAll(LINK_PATTERN, $link)) {
        if ($m.groups[1] == "next") {
            def url as string init $m.groups[0];
            if (not strings.startsWith($url, $c.url + "/")) {
                fail($what + ": the next page is not under " + $c.url + ": " +
                    shown(withoutQuery($url)));
            }
            return strings.substring($url, len($c.url), len($url));
        }
    }
    return "";
}

/**
 * GET every page of a list.
 *
 * @param c {Client} the client
 * @param path {string} the path, query string allowed
 * @return {Paged} the first reply and every entry
 */
func collect(c as Client, path as string) {
    def what as string init "GET " + withoutQuery($path);
    def url as string init $path;
    if (not regex.matches('[?&]per_page=', $url)) {
        def sep as string init "?";
        if (strings.contains($url, "?")) {
            $sep = "&";
        }
        $url = $url + $sep + "per_page=" + convert.toString(PAGE_SIZE);
    }
    def out as Paged init Paged{first: json.decode("null"), entries: []};
    def page as int init 0;
    while ($url != "") {
        $page = $page + 1;
        if ($page > MAX_PAGES) {
            throw Error{
                kind: "limit",
                message: "github: " + $what + ": more than " + convert.toString(MAX_PAGES) +
                    " pages"
            };
        }
        def r as http.Response init exchange($c, "GET", $url, "");
        def doc as json.Value init decoded($r.body, $what);
        if ($page == 1) {
            $out.first = $doc;
        }
        for (def p in items($doc, listAt($doc, $what))) {
            $out.entries[] = json.get($doc, $p);
        }
        $url = nextPath($c, http.header($r, "Link"), $what);
    }
    return $out;
}

/**
 * GET every page of a list endpoint, `PAGE_SIZE` entries a page, following
 * the `Link` header's `next`. A reply that is an object holding one list
 * (a search's `items`, `workflow_runs`, ...) gives that list's entries.
 *
 * @param c {Client} the client
 * @param path {string} the path under the REST base, query string allowed;
 *   `per_page` is added unless it is there
 * @return {list of json.Value} the entries
 * @throws {GithubError} kind `"github"` as `call`, when a reply holds no
 *   list, or when the next page is on another server
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func getAll(c as Client, path as string) {
    return collect($c, $path).entries;
}

/**
 * Build a JSON object from text fields and flags.
 *
 * @param fields {map of string to string} string members; "" values left out
 * @param flags {map of string to bool} boolean members
 * @return {string} the JSON
 */
func objectOf(fields as map of string to string, flags as map of string to bool) {
    def doc as json.Value init json.decode('{}');
    for (def key in lists.sort(maps.keys($fields))) {
        if ($fields[$key] != "") {
            $doc = json.set($doc, "/" + $key, $fields[$key]);
        }
    }
    for (def key in lists.sort(maps.keys($flags))) {
        $doc = json.set($doc, "/" + $key, $flags[$key]);
    }
    return json.encode($doc);
}

/**
 * A JSON list of strings, for a request body.
 *
 * @param names {list of string} the strings
 * @return {json.Value} the list
 */
func stringList(names as list of string) {
    return json.decode(json.encode($names));
}

/**
 * Run a GraphQL query or mutation against the client's GraphQL endpoint,
 * with its token, certificate settings and timeout. A query (not a
 * mutation) is retried on 429 or 5xx as `withRetries` allows.
 *
 * @param c {Client} the client
 * @param query {string} the document
 * @param variables {json.Value} its variables; `json.map()` for none
 * @return {json.Value} the reply's `data`
 * @throws {GithubError} kind `"github"` on an `errors` reply (status 200
 *   when GitHub answered 200, as for `RATE_LIMITED`), a refusal or a
 *   network failure
 * @example
 *   def v as json.Value init json.set(json.map(), "/login", "octocat");
 *   def d as json.Value init github.graphql($c, "query($login:String!){user(login:$login){name}}", $v);
 */
export func graphql(c as Client, query as string, variables as json.Value) {
    if (strings.trim($query) == "") {
        fail("a GraphQL request needs a query");
    }
    checkPlain($c);
    def g as gql.Client init gql.client($c.graphqlUrl);
    if ($c.token != "") {
        $g = gql.bearer($g, $c.token);
    }
    $g = gql.header($g, "User-Agent", $c.userAgent);
    if ($c.tls.skipVerify) {
        $g = gql.insecure($g);
    } elseif (len($c.tls.caCert) > 0) {
        $g = gql.withCA($g, $c.tls.caCert);
    }
    $g = gql.withTimeout($g, $c.timeoutMs);
    $g = gql.withRetries($g, $c.retries);
    $g = gql.withBackoff($g, BACKOFF_MS);
    def reply as json.Value init json.decode("null");
    try {
        $reply = gql.query($g, $query, $variables);
    } catch (e) {
        if ($e.kind == "graphql") {
            failStatus("POST /graphql: " + plain($e.message, REASON), $e.status);
        }
        failTransport("POST /graphql", $e);
    }
    if (kindAt($reply, "/data") == "missing") {
        return json.decode("null");
    }
    return json.get($reply, "/data");
}

/**
 * An account from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the account's pointer; "" for the root
 * @return {User} the account
 */
func userFrom(d as json.Value, p as string) {
    return User{
        id: numberAt($d, $p + "/id"),
        login: field($d, $p + "/login"),
        name: field($d, $p + "/name"),
        email: field($d, $p + "/email"),
        isAdmin: flag($d, $p + "/site_admin")
    };
}

/**
 * The account the token belongs to.
 *
 * @param c {Client} the client
 * @return {User} the account
 * @throws {GithubError} kind `"github"` without a valid token (HTTP 401), or
 *   as `call`
 */
export func currentUser(c as Client) {
    return userFrom(call($c, "GET", "/user", ""), "");
}

/**
 * The REST rate limit of the token, or of the caller's address without
 * one. Asking does not count against it.
 *
 * @param c {Client} the client
 * @return {RateLimit} the core limit
 * @throws {GithubError} kind `"github"` as `call`; an Enterprise Server
 *   without rate limits answers HTTP 404
 */
export func rateLimit(c as Client) {
    def d as json.Value init call($c, "GET", "/rate_limit", "");
    return RateLimit{
        limit: numberAt($d, "/resources/core/limit"),
        remaining: numberAt($d, "/resources/core/remaining"),
        used: numberAt($d, "/resources/core/used"),
        reset: numberAt($d, "/resources/core/reset")
    };
}

/**
 * A repository from a reply.
 *
 * @param d {json.Value} the document
 * @return {Repository} the repository
 */
func repositoryFrom(d as json.Value) {
    return Repository{
        id: numberAt($d, "/id"),
        owner: field($d, "/owner/login"),
        name: field($d, "/name"),
        fullName: field($d, "/full_name"),
        description: field($d, "/description"),
        isPrivate: flag($d, "/private"),
        isFork: flag($d, "/fork"),
        isArchived: flag($d, "/archived"),
        defaultBranch: field($d, "/default_branch"),
        htmlUrl: field($d, "/html_url"),
        cloneUrl: field($d, "/clone_url"),
        sshUrl: field($d, "/ssh_url"),
        stars: numberAt($d, "/stargazers_count"),
        openIssues: numberAt($d, "/open_issues_count"),
        updated: field($d, "/updated_at")
    };
}

/**
 * Repositories from list entries.
 *
 * @param docs {list of json.Value} the entries
 * @return {list of Repository} the repositories
 */
func repositoriesFrom(docs as list of json.Value) {
    def out as list of Repository init [];
    for (def d in $docs) {
        $out[] = repositoryFrom($d);
    }
    return $out;
}

/**
 * One repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {Repository} the repository
 * @throws {GithubError} kind `"github"` when it does not exist or the token
 *   may not see it (HTTP 404), or as `call`
 */
export func repository(c as Client, repo as string) {
    return repositoryFrom(call($c, "GET", repoPath($repo), ""));
}

/**
 * The public repositories of a user or organization.
 *
 * @param c {Client} the client
 * @param owner {string} a user or organization
 * @return {list of Repository} the repositories
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func repositories(c as Client, owner as string) {
    return repositoriesFrom(getAll($c, "/users/" + checkOwner($owner) + "/repos"));
}

/**
 * The repositories the token may reach: its own, and those of its
 * organizations and collaborations.
 *
 * @param c {Client} the client
 * @return {list of Repository} the repositories
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func myRepositories(c as Client) {
    return repositoriesFrom(getAll($c, "/user/repos"));
}

/**
 * Create an empty repository.
 *
 * @param c {Client} the client
 * @param owner {string} an organization; "" for the token's own account
 * @param name {string} the name
 * @param description {string} the description; "" for none
 * @param isPrivate {bool} whether it is private
 * @return {Repository} the new repository
 * @throws {GithubError} kind `"github"` when the name is taken or not
 *   allowed (HTTP 422)
 */
export func createRepository(
    c as Client,
    owner as string,
    name as string,
    description as string,
    isPrivate as bool) {
    def path as string init "/user/repos";
    if ($owner != "") {
        $path = "/orgs/" + checkOwner($owner) + "/repos";
    }
    checkOwner($name);
    def body as string init objectOf(
        {"name": $name, "description": $description},
        {"private": $isPrivate});
    return repositoryFrom(call($c, "POST", $path, $body));
}

/**
 * Delete a repository, with its issues, pull requests and releases. There is
 * no undo. The token needs the `delete_repo` scope or the Administration
 * permission.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @throws {GithubError} kind `"github"` when the token may not (HTTP 403),
 *   or as `call`
 */
export func deleteRepository(c as Client, repo as string) {
    call($c, "DELETE", repoPath($repo), "");
}

/**
 * Change a repository's description and homepage.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param description {string} the new description; "" to keep it
 * @param homepage {string} the new homepage URL; "" to keep it
 * @return {Repository} the repository
 * @throws {GithubError} kind `"github"` as `call`
 */
export func editRepository(c as Client, repo as string, description as string, homepage as string) {
    def doc as string init objectOf({"description": $description, "homepage": $homepage}, {});
    return repositoryFrom(call($c, "PATCH", repoPath($repo), $doc));
}

/**
 * Archive a repository, or bring it back. An archived one is read-only.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param archived {bool} whether it is archived
 * @return {Repository} the repository
 * @throws {GithubError} kind `"github"` as `call`
 */
export func setArchived(c as Client, repo as string, archived as bool) {
    def doc as string init objectOf({}, {"archived": $archived});
    return repositoryFrom(call($c, "PATCH", repoPath($repo), $doc));
}

/**
 * Change a repository's default branch.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param branch {string} an existing branch
 * @return {Repository} the repository
 * @throws {GithubError} kind `"github"` on an empty name, or as `call`
 */
export func setDefaultBranch(c as Client, repo as string, branch as string) {
    segments($branch, "branch");
    return repositoryFrom(call(
        $c,
        "PATCH",
        repoPath($repo),
        objectOf({"default_branch": $branch}, {})));
}

/**
 * Fork a repository. GitHub copies it in the background; the fork may be
 * empty for a moment.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name` to fork
 * @param organization {string} the organization to fork into; "" for the
 *   token's account
 * @param name {string} the fork's name; "" for the same name
 * @return {Repository} the fork
 * @throws {GithubError} kind `"github"` on a bad name, or as `call`
 */
export func forkRepository(c as Client, repo as string, organization as string, name as string) {
    if ($organization != "") {
        checkOwner($organization);
    }
    if ($name != "") {
        checkOwner($name);
    }
    def doc as string init objectOf({"organization": $organization, "name": $name}, {});
    return repositoryFrom(call($c, "POST", repoPath($repo) + "/forks", $doc));
}

/**
 * Search repositories with GitHub's search syntax. GitHub returns at most
 * 1000 results of a search.
 *
 * @param c {Client} the client
 * @param query {string} e.g. `jennifer language:go stars:>10`
 * @return {list of Repository} the matches, best first
 * @throws {GithubError} kind `"github"` on an empty query, or as `getAll`
 */
export func searchRepositories(c as Client, query as string) {
    if (strings.trim($query) == "") {
        fail("a search needs a query");
    }
    return repositoriesFrom(getAll($c, "/search/repositories?q=" + uri.encode($query)));
}

/**
 * The collaborators of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of User} the collaborators
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func collaborators(c as Client, repo as string) {
    def out as list of User init [];
    for (def d in getAll($c, repoPath($repo) + "/collaborators")) {
        $out[] = userFrom($d, "");
    }
    return $out;
}

# The permissions a collaborator can be given.
def const PERMISSIONS as list of string init ["pull", "triage", "push", "maintain", "admin"];

/**
 * Invite a collaborator, or change what one may do. On a user's own
 * repository GitHub sends an invitation the user must accept.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the user
 * @param permission {string} `pull`, `triage`, `push`, `maintain` or `admin`
 * @throws {GithubError} kind `"github"` on another permission, or as `call`
 */
export func addCollaborator(c as Client, repo as string, name as string, permission as string) {
    if (not lists.contains(PERMISSIONS, $permission)) {
        fail("a permission is one of " + strings.join(PERMISSIONS, ", ") + ", got " +
            shown($permission));
    }
    def path as string init repoPath($repo) + "/collaborators/" + checkOwner($name);
    call($c, "PUT", $path, objectOf({"permission": $permission}, {}));
}

/**
 * Remove a collaborator.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the user
 * @throws {GithubError} kind `"github"` as `call`
 */
export func removeCollaborator(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/collaborators/" + checkOwner($name), "");
}

/**
 * A webhook from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Hook} the hook
 */
func hookFrom(d as json.Value) {
    def events as list of string init [];
    for (def p in items($d, "/events")) {
        $events[] = field($d, $p);
    }
    return Hook{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        url: field($d, "/config/url"),
        events: $events,
        active: flag($d, "/active")
    };
}

/**
 * The webhooks of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of Hook} the webhooks
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func hooks(c as Client, repo as string) {
    def out as list of Hook init [];
    for (def d in getAll($c, repoPath($repo) + "/hooks")) {
        $out[] = hookFrom($d);
    }
    return $out;
}

/**
 * Add a webhook that posts JSON to a URL.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param url {string} where to post, `https://...`
 * @param secret {string} the secret the payload is signed with
 *   (`X-Hub-Signature-256`); "" for none
 * @param events {list of string} the events, e.g. `["push", "pull_request"]`
 * @return {Hook} the new webhook
 * @throws {GithubError} kind `"github"` on a URL that is not http(s), no
 *   events, or as `call`
 */
export func createHook(
    c as Client,
    repo as string,
    url as string,
    secret as string,
    events as list of string) {
    if (not regex.matches('^https?://[^\s]+$', $url)) {
        fail("a webhook URL is http:// or https://, got " + shown($url));
    }
    if (len($events) == 0) {
        fail("a webhook fires on at least one event");
    }
    def doc as json.Value init json.decode('{"name":"web","active":true}');
    $doc = json.set(
        $doc,
        "/config",
        json.decode(objectOf({"url": $url, "content_type": "json", "secret": $secret}, {})));
    $doc = json.set($doc, "/events", stringList($events));
    return hookFrom(call($c, "POST", repoPath($repo) + "/hooks", json.encode($doc)));
}

/**
 * Delete a webhook.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the hook id
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteHook(c as Client, repo as string, id as int) {
    call($c, "DELETE", repoPath($repo) + "/hooks/" + convert.toString($id), "");
}

/**
 * The branches of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of Branch} the branches
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func branches(c as Client, repo as string) {
    def out as list of Branch init [];
    for (def d in getAll($c, repoPath($repo) + "/branches")) {
        $out[] = Branch{
            name: field($d, "/name"),
            sha: field($d, "/commit/sha"),
            isProtected: flag($d, "/protected")
        };
    }
    return $out;
}

/**
 * The tags of a repository, without their annotations.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of Tag} the tags
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func tags(c as Client, repo as string) {
    def out as list of Tag init [];
    for (def d in getAll($c, repoPath($repo) + "/tags")) {
        $out[] = Tag{name: field($d, "/name"), sha: field($d, "/commit/sha"), message: ""};
    }
    return $out;
}

/**
 * The commit a branch, tag or SHA names. "" names the default branch.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} the ref
 * @return {string} the commit SHA
 */
func commitOf(c as Client, repo as string, ref as string) {
    if (regex.matches('^[0-9a-f]{40}$', $ref)) {
        return $ref;
    }
    def name as string init $ref;
    if ($name == "") {
        $name = repository($c, $repo).defaultBranch;
    }
    def path as string init repoPath($repo) + "/commits/" + uri.encode(checked($name, "ref"));
    def sha as string init field(call($c, "GET", $path, ""), "/sha");
    if ($sha == "") {
        fail("GET " + $path + ": the reply names no commit");
    }
    return $sha;
}

/**
 * Point a new ref at an object.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} the full ref, `refs/heads/x` or `refs/tags/x`
 * @param sha {string} the object
 * @return {json.Value} the new ref
 */
func createRef(c as Client, repo as string, ref as string, sha as string) {
    def doc as string init objectOf({"ref": $ref, "sha": $sha}, {});
    return call($c, "POST", repoPath($repo) + "/git/refs", $doc);
}

/**
 * Create a branch.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the new branch
 * @param from {string} the branch, tag or commit it starts at; "" for the
 *   default branch
 * @return {Branch} the new branch
 * @throws {GithubError} kind `"github"` on a bad name, or when it exists
 *   (HTTP 422)
 */
export func createBranch(c as Client, repo as string, name as string, from as string) {
    segments($name, "branch");
    def sha as string init commitOf($c, $repo, $from);
    def d as json.Value init createRef($c, $repo, "refs/heads/" + $name, $sha);
    return Branch{name: $name, sha: field($d, "/object/sha"), isProtected: false};
}

/**
 * Delete a branch.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the branch
 * @throws {GithubError} kind `"github"` when it is protected or the default
 *   branch (HTTP 422), or as `call`
 */
export func deleteBranch(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/git/refs/heads/" + segments($name, "branch"), "");
}

/**
 * Create a tag: a lightweight one, or with a message an annotated one (a
 * tag object, then its ref).
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the tag, e.g. `1.2.0`
 * @param target {string} the branch, tag or commit to tag; "" for the
 *   default branch
 * @param message {string} the annotation; "" for a lightweight tag
 * @return {Tag} the new tag
 * @throws {GithubError} kind `"github"` on a bad name, or when it exists
 *   (HTTP 422)
 */
export func createTag(
    c as Client,
    repo as string,
    name as string,
    target as string,
    message as string) {
    segments($name, "tag");
    def sha as string init commitOf($c, $repo, $target);
    def object as string init $sha;
    if ($message != "") {
        def doc as string init objectOf(
            {
                "tag": $name,
                "message": $message,
                "object": $sha,
                "type": "commit"
            },
            {});
        $object = field(call($c, "POST", repoPath($repo) + "/git/tags", $doc), "/sha");
    }
    createRef($c, $repo, "refs/tags/" + $name, $object);
    return Tag{name: $name, sha: $sha, message: $message};
}

/**
 * Delete a tag. A release of it stays, as a draft.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the tag
 * @throws {GithubError} kind `"github"` when it is protected, or as `call`
 */
export func deleteTag(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/git/refs/tags/" + segments($name, "tag"), "");
}

/**
 * GET bytes from a URL with the given headers, a non-2xx refused.
 *
 * @param c {Client} the client
 * @param url {string} the absolute URL
 * @param headers {map of string to string} the headers
 * @param maxBytes {int} the largest reply accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {http.BytesResponse} the response, 2xx or 3xx
 */
func fetchBytes(c as Client, url as string, headers as map of string to string, maxBytes as int) {
    checkPlain($c);
    def what as string init "GET " + withoutQuery($url);
    def r as http.BytesResponse;
    try {
        $r = http.requestWithBytes("GET", $url, $headers, "", idleMs($c), $maxBytes, $c.tls);
    } catch (e) {
        failTransport($what, $e);
    }
    if ($r.status < 200 or $r.status >= 400) {
        def text as string init "";
        try {
            $text = convert.stringFromBytes("utf-8", $r.body);
        } catch (e) {
            $text = "";
        }
        failStatus(
            $what + ": " + failureText($r.status, $r.statusText, $r.headers, $text),
            $r.status);
    }
    return $r;
}

/**
 * Read a file from a repository, as its raw bytes. GitHub serves files up
 * to 100 MB this way; a file in Git LFS comes as its pointer.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param path {string} the file, e.g. `docs/index.md`
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param maxBytes {int} the largest file accepted, at most `MAX_FILE_BYTES`;
 *   0 for 64 MiB, negative for no limit (as `downloadAsset`)
 * @return {bytes} the content
 * @throws {GithubError} kind `"github"` when it does not exist, when it is
 *   a directory or a submodule, when `maxBytes` is over `MAX_FILE_BYTES`
 *   (status 0 for both), or on a network failure
 * @throws {Error} kind `"limit"` for a file over `maxBytes`
 * @example
 *   def v as bytes init github.readFile($c, "me/app", "VERSION", "main", 4096);
 */
export func readFile(c as Client, repo as string, path as string, ref as string, maxBytes as int) {
    if ($maxBytes > MAX_FILE_BYTES) {
        fail("a file is read up to " + convert.toString(MAX_FILE_BYTES) + " bytes, got maxBytes " +
            convert.toString($maxBytes));
    }
    def url as string init $c.url + repoPath($repo) + "/contents/" + segments($path, "file path");
    if ($ref != "") {
        $url = $url + "?ref=" + uri.encode(checked($ref, "ref"));
    }
    def headers as map of string to string init apiHeaders($c);
    $headers["Accept"] = "application/vnd.github.raw+json";
    def r as http.BytesResponse init fetchBytes($c, $url, $headers, $maxBytes);
    if ($r.status >= 300) {
        failStatus(
            "GET " + withoutQuery($url) + ": HTTP " + convert.toString($r.status) +
                ": a redirect, not the file",
            $r.status);
    }
    # A directory or a submodule ignores the raw media type and comes as its
    # JSON description, `application/json`; a file comes as itself.
    def media as string init strings.lower(headerOf($r.headers, "content-type"));
    if (strings.contains($media, ";")) {
        $media = strings.trim(strings.substring($media, 0, strings.indexOf($media, ";")));
    }
    if ($media == "application/json") {
        fail("GET " + withoutQuery($url) + ": " + shown($path) + " is not a file");
    }
    return $r.body;
}

/**
 * The blob SHA of a file, which replacing or deleting it requires.
 *
 * @param c {Client} the client
 * @param file {string} the file's contents path
 * @param branch {string} the branch; "" for the default branch
 * @return {string} the SHA; "" when the file does not exist
 */
func blobSha(c as Client, file as string, branch as string) {
    def query as string init "";
    if ($branch != "") {
        $query = "?ref=" + uri.encode(checked($branch, "branch"));
    }
    try {
        return field(call($c, "GET", $file + $query, ""), "/sha");
    } catch (e) {
        # a missing file is a 404 for this GET; anything else is a failure
        if ($e.kind != ERROR_KIND or $e.status != 404) {
            throw $e;
        }
    }
    return "";
}

/**
 * Create or replace a file with a commit of its own.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param path {string} the file, e.g. `data/version.txt`
 * @param data {bytes} the new content
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {GithubError} kind `"github"` on an empty message, a bad path, or
 *   as `call` (HTTP 409 when the branch moved meanwhile)
 */
export func writeFile(
    c as Client,
    repo as string,
    path as string,
    data as bytes,
    message as string,
    branch as string) {
    if (strings.trim($message) == "") {
        fail("a commit needs a message");
    }
    def file as string init repoPath($repo) + "/contents/" + segments($path, "file path");
    def fields as map of string to string init {
        "message": $message,
        "branch": $branch,
        "sha": blobSha($c, $file, $branch)
    };
    # `content` is required even for an empty file, which objectOf would drop.
    def doc as json.Value init json.decode(objectOf($fields, {}));
    $doc = json.set($doc, "/content", encoding.toText("base64", $data));
    return field(call($c, "PUT", $file, json.encode($doc)), "/commit/sha");
}

/**
 * Delete a file with a commit of its own.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param path {string} the file
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {GithubError} kind `"github"` on an empty message, when the file
 *   does not exist, or as `call`
 */
export func deleteFile(
    c as Client,
    repo as string,
    path as string,
    message as string,
    branch as string) {
    if (strings.trim($message) == "") {
        fail("a commit needs a message");
    }
    def file as string init repoPath($repo) + "/contents/" + segments($path, "file path");
    def sha as string init blobSha($c, $file, $branch);
    if ($sha == "") {
        failStatus("DELETE " + $file + ": " + shown($path) + " is not a file", 404);
    }
    def doc as string init objectOf({"message": $message, "branch": $branch, "sha": $sha}, {});
    return field(call($c, "DELETE", $file, $doc), "/commit/sha");
}

/**
 * The entries of a directory in a repository. GitHub lists at most 1000.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param path {string} the directory; "" for the root
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @return {list of Entry} the entries
 * @throws {GithubError} kind `"github"` when it does not exist or is a
 *   file, or as `call`
 */
export func listDirectory(c as Client, repo as string, path as string, ref as string) {
    def url as string init repoPath($repo) + "/contents";
    if ($path != "") {
        $url = $url + "/" + segments($path, "directory");
    }
    if ($ref != "") {
        $url = $url + "?ref=" + uri.encode(checked($ref, "ref"));
    }
    def d as json.Value init call($c, "GET", $url, "");
    if (kindAt($d, "") != "list") {
        fail("GET " + withoutQuery($url) + ": " + shown($path) + " is not a directory");
    }
    def out as list of Entry init [];
    for (def p in items($d, "")) {
        $out[] = Entry{
            name: field($d, $p + "/name"),
            path: field($d, $p + "/path"),
            type: field($d, $p + "/type"),
            size: numberAt($d, $p + "/size"),
            sha: field($d, $p + "/sha")
        };
    }
    return $out;
}

/**
 * The names under a list member.
 *
 * @param d {json.Value} the document
 * @param ptr {string} the list's pointer
 * @param key {string} the member of each entry
 * @return {list of string} the values
 */
func namesAt(d as json.Value, ptr as string, key as string) {
    def out as list of string init [];
    for (def p in items($d, $ptr)) {
        $out[] = field($d, $p + "/" + $key);
    }
    return $out;
}

/**
 * An issue from a reply.
 *
 * @param d {json.Value} the document
 * @return {Issue} the issue
 */
func issueFrom(d as json.Value) {
    return Issue{
        number: numberAt($d, "/number"),
        title: field($d, "/title"),
        body: field($d, "/body"),
        state: field($d, "/state"),
        author: field($d, "/user/login"),
        labels: namesAt($d, "/labels", "name"),
        assignees: namesAt($d, "/assignees", "login"),
        comments: numberAt($d, "/comments"),
        isPull: kindAt($d, "/pull_request") == "map",
        created: field($d, "/created_at"),
        updated: field($d, "/updated_at"),
        closed: field($d, "/closed_at"),
        htmlUrl: field($d, "/html_url")
    };
}

/**
 * Check an issue, pull request or milestone state filter.
 *
 * @param state {string} the filter
 * @return {string} the filter
 */
func checkState(state as string) {
    if (not lists.contains(["open", "closed", "all"], $state)) {
        fail("a state is open, closed or all, got " + shown($state));
    }
    return $state;
}

/**
 * The path of an issue or pull request.
 *
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {string} `/repos/owner/name/issues/<n>`
 */
func issuePath(repo as string, number as int) {
    return repoPath($repo) + "/issues/" + convert.toString($number);
}

/**
 * The issues of a repository, newest first, without pull requests (which
 * GitHub's listing mixes in).
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param state {string} `open`, `closed` or `all`
 * @return {list of Issue} the issues
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func issues(c as Client, repo as string, state as string) {
    def out as list of Issue init [];
    for (def d in getAll($c, repoPath($repo) + "/issues?state=" + checkState($state))) {
        if (kindAt($d, "/pull_request") != "map") {
            $out[] = issueFrom($d);
        }
    }
    return $out;
}

/**
 * Search issues and pull requests with GitHub's search syntax. GitHub
 * returns at most 1000 results of a search.
 *
 * @param c {Client} the client
 * @param query {string} e.g. `repo:octocat/hello-world is:issue is:open label:bug`
 * @return {list of Issue} the matches, best first
 * @throws {GithubError} kind `"github"` on an empty query, or as `getAll`
 */
export func searchIssues(c as Client, query as string) {
    if (strings.trim($query) == "") {
        fail("a search needs a query");
    }
    def out as list of Issue init [];
    for (def d in getAll($c, "/search/issues?q=" + uri.encode($query))) {
        $out[] = issueFrom($d);
    }
    return $out;
}

/**
 * One issue, or a pull request as an issue.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} the issue number
 * @return {Issue} the issue
 * @throws {GithubError} kind `"github"` when it does not exist (HTTP 404),
 *   or as `call`
 */
export func issue(c as Client, repo as string, number as int) {
    return issueFrom(call($c, "GET", issuePath($repo, $number), ""));
}

/**
 * Open an issue.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param title {string} the title
 * @param body {string} the text, Markdown; "" for none
 * @return {Issue} the new issue
 * @throws {GithubError} kind `"github"` on an empty title, or as `call`
 *   (HTTP 410 when issues are turned off)
 */
export func createIssue(c as Client, repo as string, title as string, body as string) {
    if (strings.trim($title) == "") {
        fail("an issue needs a title");
    }
    def doc as string init objectOf({"title": $title, "body": $body}, {});
    return issueFrom(call($c, "POST", repoPath($repo) + "/issues", $doc));
}

/**
 * Close an issue or pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {Issue} the closed issue
 * @throws {GithubError} kind `"github"` as `call`
 */
export func closeIssue(c as Client, repo as string, number as int) {
    return issueFrom(call(
        $c,
        "PATCH",
        issuePath($repo, $number),
        objectOf({"state": "closed"}, {})));
}

/**
 * Reopen an issue or pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {Issue} the reopened issue
 * @throws {GithubError} kind `"github"` as `call`
 */
export func reopenIssue(c as Client, repo as string, number as int) {
    return issueFrom(call($c, "PATCH", issuePath($repo, $number), objectOf({"state": "open"}, {})));
}

/**
 * Change an issue's title or text.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} the issue or pull request number
 * @param title {string} the new title; "" to keep it
 * @param body {string} the new text; "" to keep it
 * @return {Issue} the issue
 * @throws {GithubError} kind `"github"` as `call`
 */
export func editIssue(c as Client, repo as string, number as int, title as string, body as string) {
    def doc as string init objectOf({"title": $title, "body": $body}, {});
    return issueFrom(call($c, "PATCH", issuePath($repo, $number), $doc));
}

/**
 * Set who is assigned to an issue or pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param names {list of string} the user names; `[]` for nobody
 * @return {Issue} the issue
 * @throws {GithubError} kind `"github"` on a bad name, or as `call`
 */
export func setAssignees(c as Client, repo as string, number as int, names as list of string) {
    for (def name in $names) {
        checkOwner($name);
    }
    def doc as json.Value init json.set(json.decode('{}'), "/assignees", stringList($names));
    return issueFrom(call($c, "PATCH", issuePath($repo, $number), json.encode($doc)));
}

/**
 * Put an issue or pull request in a milestone.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param milestone {int} the milestone's number; 0 for none
 * @return {Issue} the issue
 * @throws {GithubError} kind `"github"` as `call`
 */
export func setMilestone(c as Client, repo as string, number as int, milestone as int) {
    def doc as json.Value init json.decode('{"milestone":null}');
    if ($milestone != 0) {
        $doc = json.set($doc, "/milestone", $milestone);
    }
    return issueFrom(call($c, "PATCH", issuePath($repo, $number), json.encode($doc)));
}

/**
 * A comment from a reply.
 *
 * @param d {json.Value} the document
 * @return {Comment} the comment
 */
func commentFrom(d as json.Value) {
    return Comment{
        id: numberAt($d, "/id"),
        author: field($d, "/user/login"),
        body: field($d, "/body"),
        created: field($d, "/created_at"),
        htmlUrl: field($d, "/html_url")
    };
}

/**
 * The comments on an issue or pull request, oldest first. Review comments
 * on a pull request's code are not among them.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {list of Comment} the comments
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func comments(c as Client, repo as string, number as int) {
    def out as list of Comment init [];
    for (def d in getAll($c, issuePath($repo, $number) + "/comments")) {
        $out[] = commentFrom($d);
    }
    return $out;
}

/**
 * Comment on an issue or pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param body {string} the text, Markdown
 * @return {Comment} the new comment
 * @throws {GithubError} kind `"github"` on an empty text, or as `call`
 */
export func comment(c as Client, repo as string, number as int, body as string) {
    if (strings.trim($body) == "") {
        fail("a comment needs a text");
    }
    def path as string init issuePath($repo, $number) + "/comments";
    return commentFrom(call($c, "POST", $path, objectOf({"body": $body}, {})));
}

/**
 * Change a comment's text.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the comment id
 * @param body {string} the new text
 * @return {Comment} the comment
 * @throws {GithubError} kind `"github"` on an empty text, or as `call`
 */
export func editComment(c as Client, repo as string, id as int, body as string) {
    if (strings.trim($body) == "") {
        fail("a comment needs a text");
    }
    def path as string init repoPath($repo) + "/issues/comments/" + convert.toString($id);
    return commentFrom(call($c, "PATCH", $path, objectOf({"body": $body}, {})));
}

/**
 * Delete a comment.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the comment id
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteComment(c as Client, repo as string, id as int) {
    call($c, "DELETE", repoPath($repo) + "/issues/comments/" + convert.toString($id), "");
}

/**
 * A label from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the label's pointer; "" for the root
 * @return {Label} the label
 */
func labelFrom(d as json.Value, p as string) {
    # GitHub answers `d73a4a`; `createLabel` takes `#d73a4a`.
    def color as string init field($d, $p + "/color");
    if ($color != "" and not strings.startsWith($color, "#")) {
        $color = "#" + $color;
    }
    return Label{
        id: numberAt($d, $p + "/id"),
        name: field($d, $p + "/name"),
        color: $color,
        description: field($d, $p + "/description"),
        isDefault: flag($d, $p + "/default")
    };
}

/**
 * Labels from a reply that is a list of them.
 *
 * @param d {json.Value} the reply
 * @return {list of Label} the labels
 */
func labelsFrom(d as json.Value) {
    def out as list of Label init [];
    for (def p in items($d, "")) {
        $out[] = labelFrom($d, $p);
    }
    return $out;
}

/**
 * The labels of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of Label} the labels
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func labels(c as Client, repo as string) {
    def out as list of Label init [];
    for (def d in getAll($c, repoPath($repo) + "/labels")) {
        $out[] = labelFrom($d, "");
    }
    return $out;
}

/**
 * A label name, checked.
 *
 * @param name {string} the name
 * @return {string} the name
 */
func checkLabel(name as string) {
    if (strings.trim($name) == "" or regex.matches('[\x00-\x1f\x7f]', $name)) {
        fail("a label needs a name without control characters, got " + shown($name));
    }
    return $name;
}

/**
 * Create a label.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the name
 * @param color {string} the colour, e.g. `#d73a4a`
 * @param description {string} the description; "" for none
 * @return {Label} the new label
 * @throws {GithubError} kind `"github"` on an empty name or a colour that
 *   is not `#rrggbb`, or as `call` (HTTP 422 when it exists)
 */
export func createLabel(
    c as Client,
    repo as string,
    name as string,
    color as string,
    description as string) {
    checkLabel($name);
    if (not regex.matches('^#[0-9A-Fa-f]{6}$', $color)) {
        fail("a label colour is #rrggbb, got " + shown($color));
    }
    def doc as string init objectOf(
        {
            "name": $name,
            "color": strings.substring($color, 1, 7),
            "description": $description
        },
        {});
    return labelFrom(call($c, "POST", repoPath($repo) + "/labels", $doc), "");
}

/**
 * Delete a label, from the repository and every issue that has it.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the label's name
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteLabel(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/labels/" + uri.encode(checkLabel($name)), "");
}

/**
 * Send an issue's label names.
 *
 * @param c {Client} the client
 * @param method {string} `PUT` to replace, `POST` to add
 * @param repo {string} `owner/name`
 * @param number {int} the issue number
 * @param names {list of string} label names
 * @return {list of Label} the issue's labels now
 */
func sendLabels(
    c as Client,
    method as string,
    repo as string,
    number as int,
    names as list of string) {
    for (def name in $names) {
        checkLabel($name);
    }
    def doc as json.Value init json.set(json.decode('{}'), "/labels", stringList($names));
    return labelsFrom(call($c, $method, issuePath($repo, $number) + "/labels", json.encode($doc)));
}

/**
 * Replace the labels of an issue or pull request. A name that is no label
 * yet creates one.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param names {list of string} label names; `[]` for none
 * @return {list of Label} its labels now
 * @throws {GithubError} kind `"github"` as `call`
 */
export func setIssueLabels(c as Client, repo as string, number as int, names as list of string) {
    return sendLabels($c, "PUT", $repo, $number, $names);
}

/**
 * Add labels to an issue or pull request. A name that is no label yet
 * creates one.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param names {list of string} label names
 * @return {list of Label} its labels now
 * @throws {GithubError} kind `"github"` as `call`
 */
export func addIssueLabels(c as Client, repo as string, number as int, names as list of string) {
    return sendLabels($c, "POST", $repo, $number, $names);
}

/**
 * Take a label off an issue or pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param name {string} the label name
 * @throws {GithubError} kind `"github"` when the issue does not have it
 *   (HTTP 404), or as `call`
 */
export func removeIssueLabel(c as Client, repo as string, number as int, name as string) {
    def path as string init issuePath($repo, $number) + "/labels/" + uri.encode(checkLabel($name));
    call($c, "DELETE", $path, "");
}

/**
 * A milestone from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Milestone} the milestone
 */
func milestoneFrom(d as json.Value) {
    return Milestone{
        number: numberAt($d, "/number"),
        title: field($d, "/title"),
        description: field($d, "/description"),
        state: field($d, "/state"),
        dueOn: field($d, "/due_on"),
        openIssues: numberAt($d, "/open_issues"),
        closedIssues: numberAt($d, "/closed_issues")
    };
}

/**
 * The milestones of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param state {string} `open`, `closed` or `all`
 * @return {list of Milestone} the milestones
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func milestones(c as Client, repo as string, state as string) {
    def out as list of Milestone init [];
    for (def d in getAll($c, repoPath($repo) + "/milestones?state=" + checkState($state))) {
        $out[] = milestoneFrom($d);
    }
    return $out;
}

/**
 * Create a milestone.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param title {string} the title
 * @param description {string} the description; "" for none
 * @param dueOn {string} the due date, RFC 3339 (`2026-12-31T00:00:00Z`); ""
 *   for none
 * @return {Milestone} the new milestone
 * @throws {GithubError} kind `"github"` on an empty title, or as `call`
 */
export func createMilestone(
    c as Client,
    repo as string,
    title as string,
    description as string,
    dueOn as string) {
    if (strings.trim($title) == "") {
        fail("a milestone needs a title");
    }
    def doc as string init objectOf(
        {
            "title": $title,
            "description": $description,
            "due_on": $dueOn
        },
        {});
    return milestoneFrom(call($c, "POST", repoPath($repo) + "/milestones", $doc));
}

/**
 * Close a milestone, or open it again.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} the milestone's number
 * @param closed {bool} whether it is closed
 * @return {Milestone} the milestone
 * @throws {GithubError} kind `"github"` as `call`
 */
export func setMilestoneClosed(c as Client, repo as string, number as int, closed as bool) {
    def state as string init "open";
    if ($closed) {
        $state = "closed";
    }
    def path as string init repoPath($repo) + "/milestones/" + convert.toString($number);
    return milestoneFrom(call($c, "PATCH", $path, objectOf({"state": $state}, {})));
}

/**
 * Delete a milestone. Its issues stay, without a milestone.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} the milestone's number
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteMilestone(c as Client, repo as string, number as int) {
    call($c, "DELETE", repoPath($repo) + "/milestones/" + convert.toString($number), "");
}

/**
 * A pull request from a reply.
 *
 * @param d {json.Value} the document
 * @return {PullRequest} the pull request
 */
func pullFrom(d as json.Value) {
    return PullRequest{
        number: numberAt($d, "/number"),
        title: field($d, "/title"),
        body: field($d, "/body"),
        state: field($d, "/state"),
        author: field($d, "/user/login"),
        head: field($d, "/head/ref"),
        base: field($d, "/base/ref"),
        headSha: field($d, "/head/sha"),
        isDraft: flag($d, "/draft"),
        mergeable: flag($d, "/mergeable"),
        merged: flag($d, "/merged") or field($d, "/merged_at") != "",
        mergeSha: field($d, "/merge_commit_sha"),
        htmlUrl: field($d, "/html_url")
    };
}

/**
 * The path of a pull request.
 *
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {string} `/repos/owner/name/pulls/<n>`
 */
func pullPath(repo as string, number as int) {
    return repoPath($repo) + "/pulls/" + convert.toString($number);
}

/**
 * The pull requests of a repository, newest first.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param state {string} `open`, `closed` or `all`
 * @return {list of PullRequest} the pull requests
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func pullRequests(c as Client, repo as string, state as string) {
    def out as list of PullRequest init [];
    for (def d in getAll($c, repoPath($repo) + "/pulls?state=" + checkState($state))) {
        $out[] = pullFrom($d);
    }
    return $out;
}

/**
 * One pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {PullRequest} the pull request
 * @throws {GithubError} kind `"github"` when it does not exist (HTTP 404),
 *   or as `call`
 */
export func pullRequest(c as Client, repo as string, number as int) {
    return pullFrom(call($c, "GET", pullPath($repo, $number), ""));
}

/**
 * Open a pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param head {string} the branch with the changes; `user:branch` for a fork
 * @param base {string} the branch to merge into
 * @param title {string} the title
 * @param body {string} the text, Markdown; "" for none
 * @param isDraft {bool} open it as a draft (`"draft": true`), not ready for
 *   review and not mergeable until marked ready
 * @return {PullRequest} the new pull request
 * @throws {GithubError} kind `"github"` on an empty title, or as `call`
 *   (HTTP 422 when there is nothing to merge or one is open already, or for
 *   a draft where the repository's plan has no drafts)
 * @example
 *   def pr as github.PullRequest init github.createPullRequest(
 *       $c, "me/app", "fix-crash", "main", "Fix crash", "", true);
 */
export func createPullRequest(
    c as Client,
    repo as string,
    head as string,
    base as string,
    title as string,
    body as string,
    isDraft as bool) {
    if (strings.trim($title) == "" or $head == "" or $base == "") {
        fail("a pull request needs a head, a base and a title");
    }
    def doc as string init objectOf(
        {"head": $head, "base": $base, "title": $title, "body": $body},
        {"draft": $isDraft});
    return pullFrom(call($c, "POST", repoPath($repo) + "/pulls", $doc));
}

/**
 * Merge a pull request. With `deleteBranch`, the head branch is deleted
 * afterwards when it is in the same repository; a fork's is left alone. A
 * branch GitHub already deleted (the repository's "Automatically delete
 * head branches") counts as deleted.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param style {string} one of `MERGE_STYLES`
 * @param deleteBranch {bool} delete the head branch afterwards
 * @throws {GithubError} kind `"github"` on an unknown style, when the pull
 *   request cannot be merged (HTTP 405) or its head moved (HTTP 409); when
 *   the merge succeeded but deleting the branch failed, the message starts
 *   `github: merged #<number>, but deleting branch <name> failed:` and the
 *   status is the delete's
 */
export func mergePullRequest(
    c as Client,
    repo as string,
    number as int,
    style as string,
    deleteBranch as bool) {
    if (not lists.contains(MERGE_STYLES, $style)) {
        fail("a merge style is one of " + strings.join(MERGE_STYLES, ", ") + ", got " +
            shown($style));
    }
    def head as string init "";
    if ($deleteBranch) {
        def d as json.Value init call($c, "GET", pullPath($repo, $number), "");
        if (strings.lower(field($d, "/head/repo/full_name")) == strings.lower($repo)) {
            $head = field($d, "/head/ref");
        }
    }
    def path as string init pullPath($repo, $number) + "/merge";
    call($c, "PUT", $path, objectOf({"merge_method": $style}, {}));
    if ($head == "") {
        return;
    }
    try {
        call($c, "DELETE", repoPath($repo) + "/git/refs/heads/" + segments($head, "branch"), "");
    } catch (e) {
        if ($e.kind != ERROR_KIND) {
            throw $e;
        }
        # GitHub answers 422, not 404, for a branch that is gone already
        if ($e.status == 422 and not branchExists($c, $repo, $head)) {
            return;
        }
        def why as string init $e.message;
        if (strings.startsWith($why, "github: ")) {
            $why = strings.substring($why, 8);
        }
        failStatus(
            "merged #" + convert.toString($number) + ", but deleting branch " + shown($head) +
                " failed: " + $why,
            $e.status);
    }
}

/**
 * Whether a branch exists, by its ref: a 404 is false, any other failure
 * is thrown.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param branch {string} the branch name
 * @return {bool} true when the ref is there
 */
func branchExists(c as Client, repo as string, branch as string) {
    try {
        call($c, "GET", repoPath($repo) + "/git/ref/heads/" + segments($branch, "branch"), "");
    } catch (e) {
        if ($e.kind == ERROR_KIND and $e.status == 404) {
            return false;
        }
        throw $e;
    }
    return true;
}

/**
 * Change a pull request's title or text.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param title {string} the new title; "" to keep it
 * @param body {string} the new text; "" to keep it
 * @return {PullRequest} the pull request
 * @throws {GithubError} kind `"github"` as `call`
 */
export func editPullRequest(
    c as Client,
    repo as string,
    number as int,
    title as string,
    body as string) {
    def doc as string init objectOf({"title": $title, "body": $body}, {});
    return pullFrom(call($c, "PATCH", pullPath($repo, $number), $doc));
}

/**
 * A review from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the review's pointer; "" for the root
 * @return {Review} the review
 */
func reviewFrom(d as json.Value, p as string) {
    return Review{
        id: numberAt($d, $p + "/id"),
        author: field($d, $p + "/user/login"),
        state: field($d, $p + "/state"),
        body: field($d, $p + "/body"),
        commitId: field($d, $p + "/commit_id"),
        submitted: field($d, $p + "/submitted_at")
    };
}

# What a review can say.
def const REVIEW_EVENTS as list of string init ["APPROVE", "REQUEST_CHANGES", "COMMENT"];

/**
 * Review a pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param event {string} `APPROVE`, `REQUEST_CHANGES` or `COMMENT`
 * @param body {string} the text; "" for none, which `REQUEST_CHANGES` and
 *   `COMMENT` do not allow
 * @return {Review} the review
 * @throws {GithubError} kind `"github"` on another event, or as `call`
 *   (HTTP 422 for a review of one's own pull request)
 */
export func reviewPullRequest(
    c as Client,
    repo as string,
    number as int,
    event as string,
    body as string) {
    if (not lists.contains(REVIEW_EVENTS, $event)) {
        fail("a review is APPROVE, REQUEST_CHANGES or COMMENT, got " + shown($event));
    }
    if ($event != "APPROVE" and strings.trim($body) == "") {
        fail("a " + $event + " review needs a text");
    }
    def doc as string init objectOf({"event": $event, "body": $body}, {});
    return reviewFrom(call($c, "POST", pullPath($repo, $number) + "/reviews", $doc), "");
}

/**
 * The reviews of a pull request, oldest first.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {list of Review} the reviews
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func reviews(c as Client, repo as string, number as int) {
    def out as list of Review init [];
    for (def d in getAll($c, pullPath($repo, $number) + "/reviews")) {
        $out[] = reviewFrom($d, "");
    }
    return $out;
}

/**
 * Ask users to review a pull request.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @param names {list of string} the user names, collaborators of the
 *   repository
 * @throws {GithubError} kind `"github"` on a bad name, or as `call`
 *   (HTTP 422 for a user who is no collaborator)
 */
export func requestReviewers(c as Client, repo as string, number as int, names as list of string) {
    if (len($names) == 0) {
        fail("a review request names a reviewer");
    }
    for (def name in $names) {
        checkOwner($name);
    }
    def doc as json.Value init json.set(json.decode('{}'), "/reviewers", stringList($names));
    call($c, "POST", pullPath($repo, $number) + "/requested_reviewers", json.encode($doc));
}

/**
 * The files a pull request changes. GitHub lists at most 3000.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param number {int} its number
 * @return {list of ChangedFile} the files
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func pullRequestFiles(c as Client, repo as string, number as int) {
    def out as list of ChangedFile init [];
    for (def d in getAll($c, pullPath($repo, $number) + "/files")) {
        $out[] = ChangedFile{
            filename: field($d, "/filename"),
            status: field($d, "/status"),
            additions: numberAt($d, "/additions"),
            deletions: numberAt($d, "/deletions"),
            previousFilename: field($d, "/previous_filename")
        };
    }
    return $out;
}

/**
 * An asset from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the asset's pointer; "" for the root
 * @return {Asset} the asset
 */
func assetFrom(d as json.Value, p as string) {
    return Asset{
        id: numberAt($d, $p + "/id"),
        name: field($d, $p + "/name"),
        contentType: field($d, $p + "/content_type"),
        size: numberAt($d, $p + "/size"),
        downloads: numberAt($d, $p + "/download_count"),
        downloadUrl: field($d, $p + "/browser_download_url"),
        apiUrl: field($d, $p + "/url")
    };
}

/**
 * A release from a reply.
 *
 * @param d {json.Value} the document
 * @return {Release} the release
 */
func releaseFrom(d as json.Value) {
    def assets as list of Asset init [];
    for (def p in items($d, "/assets")) {
        $assets[] = assetFrom($d, $p);
    }
    return Release{
        id: numberAt($d, "/id"),
        tag: field($d, "/tag_name"),
        name: field($d, "/name"),
        body: field($d, "/body"),
        isDraft: flag($d, "/draft"),
        isPrerelease: flag($d, "/prerelease"),
        created: field($d, "/created_at"),
        published: field($d, "/published_at"),
        htmlUrl: field($d, "/html_url"),
        assets: $assets
    };
}

/**
 * The releases of a repository, newest first. Drafts are listed only for a
 * token with push access.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of Release} the releases
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func releases(c as Client, repo as string) {
    def out as list of Release init [];
    for (def d in getAll($c, repoPath($repo) + "/releases")) {
        $out[] = releaseFrom($d);
    }
    return $out;
}

/**
 * The published release of a tag.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param tag {string} the tag, e.g. `1.2.0`
 * @return {Release} the release
 * @throws {GithubError} kind `"github"` when there is none (HTTP 404), or as
 *   `call`
 */
export func release(c as Client, repo as string, tag as string) {
    def path as string init repoPath($repo) + "/releases/tags/" + segments($tag, "tag");
    return releaseFrom(call($c, "GET", $path, ""));
}

/**
 * The release GitHub marks as the latest: by default the newest that is
 * neither a draft nor a pre-release.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {Release} the release
 * @throws {GithubError} kind `"github"` when there is none (HTTP 404), or as
 *   `call`
 */
export func latestRelease(c as Client, repo as string) {
    return releaseFrom(call($c, "GET", repoPath($repo) + "/releases/latest", ""));
}

/**
 * Publish a release, creating the tag at `target` when it does not exist.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param tag {string} the tag, e.g. `1.2.0`
 * @param target {string} the branch or commit to tag; "" for the default branch
 * @param name {string} the title; "" for the tag
 * @param body {string} the notes, Markdown; "" for none
 * @param isPrerelease {bool} mark it as a pre-release
 * @return {Release} the new release
 * @throws {GithubError} kind `"github"` as `call` (HTTP 422 when the tag has
 *   a release already)
 */
export func createRelease(
    c as Client,
    repo as string,
    tag as string,
    target as string,
    name as string,
    body as string,
    isPrerelease as bool) {
    segments($tag, "tag");
    def doc as string init objectOf(
        {
            "tag_name": $tag,
            "target_commitish": $target,
            "name": $name,
            "body": $body
        },
        {"draft": false, "prerelease": $isPrerelease});
    return releaseFrom(call($c, "POST", repoPath($repo) + "/releases", $doc));
}

/**
 * Change a release's title or notes.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the release id
 * @param name {string} the new title; "" to keep it
 * @param body {string} the new notes; "" to keep them
 * @return {Release} the release
 * @throws {GithubError} kind `"github"` as `call`
 */
export func editRelease(c as Client, repo as string, id as int, name as string, body as string) {
    def doc as string init objectOf({"name": $name, "body": $body}, {});
    def path as string init repoPath($repo) + "/releases/" + convert.toString($id);
    return releaseFrom(call($c, "PATCH", $path, $doc));
}

/**
 * Delete a release. The tag stays.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the release id
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteRelease(c as Client, repo as string, id as int) {
    call($c, "DELETE", repoPath($repo) + "/releases/" + convert.toString($id), "");
}

/**
 * Attach a file to a release, through the uploads host.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param releaseId {int} the release id
 * @param name {string} the file name
 * @param contentType {string} the media type GitHub serves it with, such as
 *   `application/gzip` or `text/plain; charset=utf-8`; "" for
 *   `application/octet-stream`
 * @param data {bytes} the content
 * @return {Asset} the new asset
 * @throws {GithubError} kind `"github"` on a bad name or media type
 *   (status 0), a network failure or a refusal (HTTP 422 when the release
 *   has a file of that name)
 * @example
 *   github.uploadAsset($c, "me/app", $rel.id, "app.tar.gz", "application/gzip", $data);
 */
export func uploadAsset(
    c as Client,
    repo as string,
    releaseId as int,
    name as string,
    contentType as string,
    data as bytes) {
    if ($name == "" or strings.contains($name, "/") or regex.matches('[\x00-\x1f\x7f]', $name)) {
        fail("an asset name holds no / or control characters, got " + shown($name));
    }
    def path as string init repoPath($repo) + "/releases/" + convert.toString($releaseId) +
        "/assets?name=" + uri.encode($name);
    def headers as map of string to string init apiHeaders($c);
    $headers["Content-Type"] = mediaType($contentType);
    checkPlain($c);
    def r as http.Response;
    try {
        $r = http.requestRawBodyTls(
            "POST",
            $c.uploadUrl + $path,
            $headers,
            $data,
            idleMs($c),
            0,
            $c.tls);
    } catch (e) {
        failTransport("POST " + $path, $e);
    }
    if ($r.status < 200 or $r.status >= 300) {
        failStatus(
            "POST " + $path + ": " + failureText($r.status, $r.statusText, $r.headers, $r.body),
            $r.status);
    }
    return assetFrom(decoded($r.body, "POST " + $path), "");
}

/**
 * The Content-Type of an upload: `application/octet-stream` for "", else
 * the media type checked as `type/subtype` with optional `; name=value`
 * parameters (RFC 9110 tokens, a value also a quoted string) and no control
 * characters.
 *
 * @param contentType {string} the caller's media type
 * @return {string} the header value
 */
func mediaType(contentType as string) {
    if ($contentType == "") {
        return "application/octet-stream";
    }
    def token as string init '[A-Za-z0-9!#$%&' + "'" + '*+.^_`|~-]+';
    def pattern as string init "^" + $token + "/" + $token + "( *; *" + $token + "=(" + $token +
        '|"[^"\\\x00-\x1f\x7f]*"))*$';
    if (regex.matches('[\x00-\x1f\x7f]', $contentType) or not regex.matches($pattern, $contentType)) {
        fail("a content type is type/subtype with optional ; name=value parameters, got " +
            shown($contentType));
    }
    return $contentType;
}

/**
 * Download a release asset through the API, which works for a private
 * repository too. GitHub answers with a redirect to its storage on another
 * host; that redirect and any after it are followed without the token,
 * which goes to the client's own server only.
 *
 * @param c {Client} the client
 * @param asset {Asset} the asset, from a `Release`
 * @param maxBytes {int} the largest file accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {GithubError} kind `"github"` when the asset is not on the
 *   client's server, a redirect leaves https, or on a refusal
 * @throws {Error} kind `"limit"` for a file over `maxBytes`, or after too
 *   many redirects
 */
export func downloadAsset(c as Client, asset as Asset, maxBytes as int) {
    if (not strings.startsWith($asset.apiUrl, $c.url + "/repos/")) {
        fail("the asset " + shown($asset.name) + " is not on " + $c.url + ": " +
            shown($asset.apiUrl));
    }
    def headers as map of string to string init apiHeaders($c);
    $headers["Accept"] = "application/octet-stream";
    def url as string init $asset.apiUrl;
    def hops as int init 0;
    while (true) {
        def r as http.BytesResponse init fetchBytes($c, $url, $headers, $maxBytes);
        if ($r.status < 300) {
            return $r.body;
        }
        def location as string init headerOf($r.headers, "location");
        if ($location == "") {
            failStatus(
                "GET " + withoutQuery($url) + ": HTTP " + convert.toString($r.status) +
                    " without a Location",
                $r.status);
        }
        $hops = $hops + 1;
        if ($hops > MAX_REDIRECTS) {
            throw Error{
                kind: "limit",
                message: "github: GET " + withoutQuery($asset.apiUrl) + ": more than " +
                    convert.toString(MAX_REDIRECTS) + " redirects"
            };
        }
        def next as string init uri.resolve($url, $location);
        if (strings.startsWith($url, "https://") and not strings.startsWith($next, "https://")) {
            fail("GET " + withoutQuery($url) + ": refused a redirect away from https: " +
                shown(withoutQuery($next)));
        }
        $url = $next;
        # The storage host gets neither the token nor GitHub's API headers.
        $headers = {"Accept": "application/octet-stream", "User-Agent": $c.userAgent};
    }
    return convert.bytesFromString("utf-8", "");
}

/**
 * Delete a file attached to a release.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param assetId {int} the asset id
 * @throws {GithubError} kind `"github"` as `call`
 */
export func deleteAsset(c as Client, repo as string, assetId as int) {
    call($c, "DELETE", repoPath($repo) + "/releases/assets/" + convert.toString($assetId), "");
}

/**
 * A commit from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Commit} the commit
 */
func commitFrom(d as json.Value) {
    return Commit{
        sha: field($d, "/sha"),
        message: field($d, "/commit/message"),
        author: field($d, "/commit/author/name"),
        authorEmail: field($d, "/commit/author/email"),
        date: field($d, "/commit/author/date"),
        htmlUrl: field($d, "/html_url")
    };
}

/**
 * The commits reachable from a ref, newest first.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param path {string} only commits that touch this file or directory; ""
 *   for all
 * @return {list of Commit} the commits
 * @throws {GithubError} kind `"github"` as `getAll` (HTTP 409 for an empty
 *   repository)
 */
export func commits(c as Client, repo as string, ref as string, path as string) {
    def query as string init repoPath($repo) + "/commits?per_page=" + convert.toString(PAGE_SIZE);
    if ($ref != "") {
        $query = $query + "&sha=" + uri.encode(checked($ref, "ref"));
    }
    if ($path != "") {
        segments($path, "file path");
        $query = $query + "&path=" + uri.encode($path);
    }
    def out as list of Commit init [];
    for (def d in getAll($c, $query)) {
        $out[] = commitFrom($d);
    }
    return $out;
}

/**
 * One commit.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param sha {string} the commit SHA, or a branch or tag
 * @return {Commit} the commit
 * @throws {GithubError} kind `"github"` when there is none (HTTP 404 or
 *   422), or as `call`
 */
export func commit(c as Client, repo as string, sha as string) {
    def path as string init repoPath($repo) + "/commits/" + uri.encode(checked($sha, "commit"));
    return commitFrom(call($c, "GET", $path, ""));
}

# The states a commit status can have.
def const STATUS_STATES as list of string init ["pending", "success", "error", "failure"];

/**
 * A commit status from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the status's pointer; "" for the root
 * @return {CommitStatus} the status
 */
func statusFrom(d as json.Value, p as string) {
    return CommitStatus{
        context: field($d, $p + "/context"),
        state: field($d, $p + "/state"),
        description: field($d, $p + "/description"),
        targetUrl: field($d, $p + "/target_url"),
        creator: field($d, $p + "/creator/login"),
        created: field($d, $p + "/created_at")
    };
}

/**
 * Set a status on a commit, as a CI system reports a check.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param sha {string} the commit SHA
 * @param state {string} `pending`, `success`, `error` or `failure`
 * @param context {string} which check it is, e.g. `ci/build`
 * @param description {string} a short text; "" for none
 * @param targetUrl {string} where the details are; "" for none
 * @return {CommitStatus} the status
 * @throws {GithubError} kind `"github"` on another state, a bad SHA, or as
 *   `call`
 * @example
 *   github.setCommitStatus($c, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);
 */
export func setCommitStatus(
    c as Client,
    repo as string,
    sha as string,
    state as string,
    context as string,
    description as string,
    targetUrl as string) {
    if (not lists.contains(STATUS_STATES, $state)) {
        fail("a commit status is one of " + strings.join(STATUS_STATES, ", ") + ", got " +
            shown($state));
    }
    def doc as string init objectOf(
        {
            "state": $state,
            "context": $context,
            "description": $description,
            "target_url": $targetUrl
        },
        {});
    def path as string init repoPath($repo) + "/statuses/" + uri.encode(checked($sha, "commit"));
    return statusFrom(call($c, "POST", $path, $doc), "");
}

/**
 * The statuses set on a commit, newest first.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} a commit SHA, branch or tag
 * @return {list of CommitStatus} the statuses
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func commitStatuses(c as Client, repo as string, ref as string) {
    def out as list of CommitStatus init [];
    def path as string init repoPath($repo) + "/commits/" + uri.encode(checked($ref, "ref")) +
        "/statuses";
    for (def d in getAll($c, $path)) {
        $out[] = statusFrom($d, "");
    }
    return $out;
}

/**
 * The combined status of a commit: the latest status per context, and the
 * worst of them. Check runs (GitHub Actions) are not in it; see
 * `checkRuns`.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} a commit SHA, branch or tag
 * @return {CombinedStatus} the combined status
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func combinedStatus(c as Client, repo as string, ref as string) {
    def path as string init repoPath($repo) + "/commits/" + uri.encode(checked($ref, "ref")) +
        "/status";
    def all as Paged init collect($c, $path);
    def statuses as list of CommitStatus init [];
    for (def d in $all.entries) {
        $statuses[] = statusFrom($d, "");
    }
    return CombinedStatus{state: field($all.first, "/state"), statuses: $statuses};
}

/**
 * The check runs on a commit: the latest run of each check, GitHub
 * Actions' jobs among them.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param ref {string} a commit SHA, branch or tag
 * @return {list of CheckRun} the check runs
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func checkRuns(c as Client, repo as string, ref as string) {
    def path as string init repoPath($repo) + "/commits/" + uri.encode(checked($ref, "ref")) +
        "/check-runs";
    def out as list of CheckRun init [];
    for (def d in getAll($c, $path)) {
        $out[] = CheckRun{
            id: numberAt($d, "/id"),
            name: field($d, "/name"),
            status: field($d, "/status"),
            conclusion: field($d, "/conclusion"),
            htmlUrl: field($d, "/html_url"),
            started: field($d, "/started_at"),
            completed: field($d, "/completed_at")
        };
    }
    return $out;
}

/**
 * Run an Actions workflow that has a `workflow_dispatch` trigger.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param workflow {string} the workflow file, e.g. `release.yml`, or its id
 * @param ref {string} the branch or tag to run it on
 * @param inputs {map of string to string} the workflow's inputs, at most
 *   `MAX_WORKFLOW_INPUTS`; `{}` for none. An input given as "" is sent as "",
 *   not left to its default.
 * @return {int} the run's id; 0 when GitHub does not report it (an
 *   Enterprise Server, which answers HTTP 204)
 * @throws {GithubError} kind `"github"` on a bad name or more than
 *   `MAX_WORKFLOW_INPUTS` inputs (status 0, nothing sent), or as `call`
 *   (HTTP 422 for a workflow without the trigger)
 */
export func dispatchWorkflow(
    c as Client,
    repo as string,
    workflow as string,
    ref as string,
    inputs as map of string to string) {
    def path as string init repoPath($repo) + "/actions/workflows/" +
        uri.encode(checked($workflow, "workflow")) +
        "/dispatches";
    return numberAt(call($c, "POST", $path, dispatchBody($c, $ref, $inputs)), "/workflow_run_id");
}

/**
 * The body of a workflow dispatch. github.com reports the new run only when
 * asked (`return_run_details`); an Enterprise Server knows no such member.
 *
 * @param c {Client} the client
 * @param ref {string} the branch or tag
 * @param inputs {map of string to string} the inputs, "" values kept
 * @return {string} the JSON
 */
func dispatchBody(c as Client, ref as string, inputs as map of string to string) {
    if ($ref == "") {
        fail("a workflow runs on a ref");
    }
    if (len($inputs) > MAX_WORKFLOW_INPUTS) {
        fail("a workflow takes at most " + convert.toString(MAX_WORKFLOW_INPUTS) + " inputs, got " +
            convert.toString(len($inputs)));
    }
    def given as json.Value init json.decode('{}');
    for (def key in lists.sort(maps.keys($inputs))) {
        if ($key == "") {
            fail("a workflow input has a name");
        }
        def p as string init "/" + strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
        $given = json.set($given, $p, $inputs[$key]);
    }
    def doc as json.Value init json.set(json.decode('{}'), "/ref", $ref);
    $doc = json.set($doc, "/inputs", $given);
    if ($c.url == "https://api.github.com") {
        $doc = json.set($doc, "/return_run_details", true);
    }
    return json.encode($doc);
}

/**
 * One run of an Actions workflow.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param id {int} the run id, e.g. from `dispatchWorkflow`
 * @return {WorkflowRun} the run
 * @throws {GithubError} kind `"github"` as `call`
 */
export func workflowRun(c as Client, repo as string, id as int) {
    def d as json.Value init call(
        $c,
        "GET",
        repoPath($repo) + "/actions/runs/" + convert.toString($id),
        "");
    return WorkflowRun{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        event: field($d, "/event"),
        status: field($d, "/status"),
        conclusion: field($d, "/conclusion"),
        headBranch: field($d, "/head_branch"),
        headSha: field($d, "/head_sha"),
        htmlUrl: field($d, "/html_url"),
        created: field($d, "/created_at")
    };
}

/**
 * Refuse a secret or variable name GitHub would not take.
 *
 * @param name {string} the name
 * @return {string} the name
 */
func checkVariable(name as string) {
    if (not regex.matches('^[A-Za-z_][A-Za-z0-9_]*$', $name) or
        strings.startsWith(strings.upper($name), "GITHUB_")) {
        fail("a secret or variable name is letters, digits and _, not starting with a digit " +
            "or GITHUB_, got " + shown($name));
    }
    return $name;
}

/**
 * The names of a repository's Actions secrets. Their values cannot be
 * read.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {list of string} the names
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func secrets(c as Client, repo as string) {
    def out as list of string init [];
    for (def d in getAll($c, repoPath($repo) + "/actions/secrets")) {
        $out[] = field($d, "/name");
    }
    return $out;
}

/**
 * Create or replace an Actions secret of a repository. The value is sealed
 * with the repository's public key (fetched first) on this machine, so only
 * the Actions runners can open it. GitHub stores the name in upper case.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the secret's name
 * @param value {string} the value, not empty, at most `MAX_SECRET_BYTES`
 *   bytes as UTF-8
 * @throws {GithubError} kind `"github"` on a bad name or value, on a public
 *   key that is not 32 bytes of base64, or as `call`
 */
export func setSecret(c as Client, repo as string, name as string, value as string) {
    checkVariable($name);
    def plain as bytes init convert.bytesFromString("utf-8", $value);
    if (len($plain) == 0 or len($plain) > MAX_SECRET_BYTES) {
        fail(
            "a secret's value is 1 to " + convert.toString(MAX_SECRET_BYTES) + " bytes, got " +
                convert.toString(len($plain)));
    }
    def path as string init repoPath($repo) + "/actions/secrets";
    def k as json.Value init call($c, "GET", $path + "/public-key", "");
    def keyId as string init field($k, "/key_id");
    if ($keyId == "" or kindAt($k, "/key") != "string") {
        fail("the repository's public key has no key_id or key");
    }
    def key as bytes;
    try {
        $key = encoding.fromText("base64", field($k, "/key"));
    } catch (e) {
        fail("the repository's public key is not base64");
    }
    if (len($key) != 32) {
        fail("the repository's public key is " + convert.toString(len($key)) +
            " bytes, not an X25519 key of 32");
    }
    def sealed as bytes;
    try {
        $sealed = crypto.wrap("nacl-sealedbox", $plain, $key);
    } catch (e) {
        # only a low-order point gets here: the length is checked above
        fail("the repository's public key is unusable: " + $e.message);
    }
    call(
        $c,
        "PUT",
        $path + "/" + $name,
        objectOf({"encrypted_value": encoding.toText("base64", $sealed), "key_id": $keyId}, {}));
}

/**
 * Delete an Actions secret of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the secret's name
 * @throws {GithubError} kind `"github"` on a bad name, or as `call`
 */
export func deleteSecret(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/actions/secrets/" + checkVariable($name), "");
}

/**
 * The Actions variables of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @return {map of string to string} each variable's value by its name
 * @throws {GithubError} kind `"github"` as `getAll`
 */
export func variables(c as Client, repo as string) {
    def out as map of string to string init {};
    for (def d in getAll($c, repoPath($repo) + "/actions/variables")) {
        $out[field($d, "/name")] = field($d, "/value");
    }
    return $out;
}

/**
 * Create or replace an Actions variable of a repository. GitHub stores the
 * name in upper case.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the variable's name
 * @param value {string} the value, not empty
 * @throws {GithubError} kind `"github"` on a bad name or an empty value, or
 *   as `call`
 */
export func setVariable(c as Client, repo as string, name as string, value as string) {
    checkVariable($name);
    if ($value == "") {
        fail("a variable needs a value");
    }
    def doc as string init objectOf({"name": $name, "value": $value}, {});
    def path as string init repoPath($repo) + "/actions/variables";
    try {
        call($c, "PATCH", $path + "/" + $name, $doc);
    } catch (e) {
        # a missing variable is a 404 for this PATCH; anything else is a failure
        if ($e.kind != ERROR_KIND or $e.status != 404) {
            throw $e;
        }
        call($c, "POST", $path, $doc);
    }
}

/**
 * Delete an Actions variable of a repository.
 *
 * @param c {Client} the client
 * @param repo {string} `owner/name`
 * @param name {string} the variable's name
 * @throws {GithubError} kind `"github"` on a bad name, or as `call`
 */
export func deleteVariable(c as Client, repo as string, name as string) {
    call($c, "DELETE", repoPath($repo) + "/actions/variables/" + checkVariable($name), "");
}

/**
 * The type of a node, `missing` when the pointer does not resolve.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer; "" for the root
 * @return {string} `null`, `bool`, `int`, `float`, `string`, `list`, `map` or `missing`
 */
func kindAt(v as json.Value, ptr as string) {
    if ($ptr == "") {
        return json.typeOf($v);
    }
    if (not json.has($v, $ptr)) {
        return "missing";
    }
    return json.typeOf($v, $ptr);
}

/**
 * Read a node as text, whatever its type.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the text; "" for absent or `null`
 */
func field(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "string") {
        return json.asString($v, $ptr);
    } elseif ($kind == "int") {
        return convert.toString(json.asInt($v, $ptr));
    } elseif ($kind == "float") {
        return convert.toString(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return "true";
        }
        return "false";
    }
    return "";
}

/**
 * Read a node as an int: a number (truncated) or a numeric string.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 for absent, `null` or not numeric
 */
func numberAt(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "int") {
        return json.asInt($v, $ptr);
    } elseif ($kind == "float") {
        return convert.toInt(json.asFloat($v, $ptr));
    } elseif ($kind == "string") {
        try {
            return convert.toInt(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0;
        }
    }
    return 0;
}

/**
 * Read a flag: `true` or `"true"`.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the flag; false for absent or `null`
 */
func flag(v as json.Value, ptr as string) {
    return field($v, $ptr) == "true";
}

/**
 * The pointers of a list's elements.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the list's pointer; "" for the root
 * @return {list of string} `<ptr>/0`, `<ptr>/1`, ...; empty when it is no list
 */
func items(v as json.Value, ptr as string) {
    def out as list of string init [];
    if (kindAt($v, $ptr) != "list") {
        return $out;
    }
    def n as int init 0;
    if ($ptr == "") {
        $n = json.length($v);
    } else {
        $n = json.length($v, $ptr);
    }
    def i as int init 0;
    while ($i < $n) {
        $out[] = $ptr + "/" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}
