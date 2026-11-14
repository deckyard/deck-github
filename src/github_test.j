# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for github: jennifer test src/github_test.j
 *
 * The checking and parsing helpers are tested directly. The requests go to an
 * `httpd` server on a loopback port that answers with canned GitHub replies
 * and hands back what it received. A client for `http://127.0.0.1:<port>` is
 * an Enterprise Server one, so the paths it sends start with `/api/v3`.
 */
use httpd;
use task;
use testing;

/** A canned reply. `BASE` in a header value stands for the server's URL. */
def struct Reply {
    status as int,
    headers as map of string to string,
    body as string
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as string,
    auth as string,
    accept as string,
    version as string,
    agent as string,
    contentType as string,
    body as bytes
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param base {string} the server's URL, for `BASE` in a header
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, base as string, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: httpd.rawQuery($req),
            auth: httpd.header($req, "Authorization"),
            accept: httpd.header($req, "Accept"),
            version: httpd.header($req, "X-GitHub-Api-Version"),
            agent: httpd.header($req, "User-Agent"),
            contentType: httpd.header($req, "Content-Type"),
            body: httpd.body($req)
        };
        httpd.setHeader($req, "Content-Type", "application/json");
        for (def name in lists.sort(maps.keys($r.headers))) {
            httpd.setHeader($req, $name, strings.replace($r.headers[$name], "BASE", $base));
        }
        httpd.respond($req, $r.status, $r.body);
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    def t as task of list of Seen init spawn {
        return serve($srv, $base, $replies);
    };
    return Fake{srv: $srv, url: $base, t: $t};
}

/**
 * Stop a fake server.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A 200 reply.
 *
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func ok(body as string) {
    return Reply{status: 200, headers: {}, body: $body};
}

/**
 * A reply with a status.
 *
 * @param status {int} the HTTP status
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func answer(status as int, body as string) {
    return Reply{status: $status, headers: {}, body: $body};
}

/**
 * A page of a list with a `Link` to the next one.
 *
 * @param body {string} the JSON list
 * @param next {string} the next page's URL; `BASE` for the server
 * @return {Reply} the reply
 */
func pageOf(body as string, next as string) {
    return Reply{
        status: 200,
        headers: {"Link": "<" + $next + '>; rel="next", <BASE/x?page=9>; rel="last"'},
        body: $body
    };
}

/**
 * A JSON list of `n` numbered objects.
 *
 * @param n {int} how many
 * @return {string} the JSON
 */
func entries(n as int) {
    def parts as list of string init [];
    def i as int init 0;
    while ($i < $n) {
        $parts[] = '{"id":' + convert.toString($i) + '}';
        $i = $i + 1;
    }
    return "[" + strings.join($parts, ",") + "]";
}

/**
 * A client for a fake server with a token.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func tokenClient(f as Fake) {
    return withToken(client($f.url), "t0k3n");
}

/**
 * A request body as JSON text.
 *
 * @param s {Seen} the request
 * @return {string} the body, re-encoded
 */
func bodyOf(s as Seen) {
    return json.encode(json.decode(convert.stringFromBytes("utf-8", $s.body)));
}

/**
 * The message of the deck's error.
 *
 * @param e {GithubError} the error
 * @return {string} its message
 */
func messageOf(e as GithubError) {
    testing.assertEqual($e.kind, ERROR_KIND);
    return $e.message;
}

/**
 * Fail a test whose call was meant to throw.
 */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

def const REPO as string init '{"id":7,"owner":{"login":"me"},"name":"app","full_name":"me/app",' +
    '"description":"An app","private":true,"fork":false,"archived":false,"default_branch":"main",' +
    '"html_url":"https://github.com/me/app","clone_url":"https://github.com/me/app.git",' +
    '"ssh_url":"git@github.com:me/app.git","stargazers_count":3,"open_issues_count":2,' +
    '"updated_at":"2026-11-03T10:00:00Z"}';

def const ISSUE as string init '{"number":12,"title":"Crash on start","body":"It crashes.",' +
    '"state":"open","user":{"login":"ada"},"labels":[{"name":"bug"},{"name":"p1"}],' +
    '"assignees":[{"login":"bob"}],"comments":4,' +
    '"created_at":"2026-11-01T09:00:00Z","updated_at":"2026-11-02T09:00:00Z","closed_at":null,' +
    '"html_url":"https://github.com/me/app/issues/12"}';

def const PULL_ISSUE as string init '{"number":15,"title":"Fix crash","state":"open",' +
    '"user":{"login":"bob"},"pull_request":{"url":"x"}}';

def const PULL as string init '{"number":15,"title":"Fix crash","body":"Fixes #12",' +
    '"state":"open","user":{"login":"bob"},' +
    '"head":{"ref":"fix-crash","sha":"abc123","repo":{"full_name":"Me/App"}},' +
    '"base":{"ref":"main","sha":"def456"},"draft":false,"mergeable":true,"merged":false,' +
    '"merged_at":null,"merge_commit_sha":null,"html_url":"https://github.com/me/app/pull/15"}';

def const SHA as string init "0123456789abcdef0123456789abcdef01234567";

func testClientAddresses() {
    def gh as Client init client("github.com");
    testing.assertEqual($gh.url, "https://api.github.com");
    testing.assertEqual($gh.uploadUrl, "https://uploads.github.com");
    testing.assertEqual($gh.graphqlUrl, "https://api.github.com/graphql");
    testing.assertEqual($gh.userAgent, USER_AGENT);
    testing.assertEqual(client("https://API.github.com/").url, "https://api.github.com");
    def ghes as Client init client("github.example.com");
    testing.assertEqual($ghes.url, "https://github.example.com/api/v3");
    testing.assertEqual($ghes.uploadUrl, "https://github.example.com/api/uploads");
    testing.assertEqual($ghes.graphqlUrl, "https://github.example.com/api/graphql");
    testing.assertEqual(
        client("https://ghe.local:8443/api/v3/").url,
        "https://ghe.local:8443/api/v3");
    testing.assertEqual(client("http://127.0.0.1:9000").url, "http://127.0.0.1:9000/api/v3");
    for (def bad in [" ", "http://github.com", "ftp://x", "https://x/git", "a b", "x?y=1"]) {
        try {
            client($bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.status, 0);
            testing.assertContains(messageOf($e), "github: ");
        }
    }
}

func testClientSettings() {
    def c as Client init withRetries(withTimeout(withInsecure(client("github.com")), 5000), 2);
    testing.assertTrue($c.tls.skipVerify);
    testing.assertEqual($c.timeoutMs, 5000);
    testing.assertEqual($c.retries, 2);
    $c = withCaCert($c, convert.bytesFromString("utf-8", "PEM"));
    testing.assertFalse($c.tls.skipVerify);
    testing.assertEqual(withToken($c, "abc").token, "abc");
    testing.assertEqual(withUserAgent($c, "my-bot").userAgent, "my-bot");
    try {
        withToken($c, "abc\r\nX-Evil: 1");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a token holds no spaces or control characters");
    }
    try {
        withUserAgent($c, " ");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a user agent");
    }
    try {
        withTimeout($c, -1);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a timeout is 0 or more milliseconds, got -1");
    }
    try {
        withRetries($c, -1);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: retries are 0 or more, got -1");
    }
}

func testNamesAndPathsAreChecked() {
    testing.assertEqual(repoPath("me/app.js"), "/repos/me/app.js");
    for (def bad in ["app", "me/app/x", "../app", "me/..", "me/a b", "me/"]) {
        try {
            repoPath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a repository is owner/name");
        }
    }
    testing.assertEqual(segments("docs/a b.md", "file path"), "docs/a%20b.md");
    testing.assertEqual(segments("release/1.0", "tag"), "release/1.0");
    testing.assertEqual(segments("v1.0+build", "tag"), "v1.0%2Bbuild");
    for (def bad in ["", "a/../b", "/a", "a//b", "a\nb"]) {
        try {
            segments($bad, "file path");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a file path");
        }
    }
    for (def bad in ["user", "/a//b", "/a/../b", "/a b", "/a#x"]) {
        try {
            ensurePath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "an API path");
        }
    }
    ensurePath("/repos/me/app/issues?state=open");
    def long as string init strings.repeat("x", 100) + convert.fromCodepoint(10);
    try {
        repoPath($long);
        missed();
    } catch (e) {
        testing.assertFalse(strings.contains(messageOf($e), convert.fromCodepoint(10)));
        testing.assertContains(messageOf($e), "...");
    }
    testing.assertEqual(withoutQuery("https://x/a?sig=1"), "https://x/a");
}

func testFailureText() {
    testing.assertEqual(
        failureText(404, "Not Found", {}, '{"message":"Not Found","documentation_url":"x"}'),
        "HTTP 404: Not Found");
    testing.assertEqual(
        failureText(
            422,
            "Unprocessable Entity",
            {},
            '{"message":"Validation Failed","errors":[{"resource":"Label","field":"name",' +
                '"code":"already_exists"},{"message":"no commits"},"plain"]}'),
        "HTTP 422: Validation Failed (name already_exists; no commits; plain)");
    testing.assertEqual(failureText(502, "Bad Gateway", {}, "<html>"), "HTTP 502: Bad Gateway");
    testing.assertEqual(
        failureText(
            403,
            "Forbidden",
            {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"},
            '{"message":"API rate limit exceeded"}'),
        "HTTP 403: API rate limit exceeded [rate limit exhausted; resets at 2027-01-15T08:00:00Z]");
    testing.assertEqual(
        failureText(429, "Too Many Requests", {"retry-after": "30"}, ""),
        "HTTP 429: Too Many Requests [rate limited; retry after 30 s]");
    testing.assertEqual(failureText(403, "Forbidden", {}, ""), "HTTP 403: Forbidden");
    # The server's text stays one bounded line.
    def said as string init failureText(
        500,
        "",
        {},
        '{"message":"line one\nforged: line two ' + strings.repeat("x", 500) + '"}');
    testing.assertFalse(strings.contains($said, convert.fromCodepoint(10)));
    testing.assertContains($said, "line one?forged");
    testing.assertTrue(len($said) < 250);
}

func testRetryWaits() {
    def now as int init 1000;
    # 5xx: 1 s doubling, raised to a Retry-After, never past the cap.
    testing.assertEqual(retryWaitMs(502, {}, 0, $now), 1000);
    testing.assertEqual(retryWaitMs(503, {}, 2, $now), 4000);
    testing.assertEqual(retryWaitMs(503, {"retry-after": "7"}, 0, $now), 7000);
    testing.assertEqual(retryWaitMs(503, {"retry-after": "600"}, 0, $now), -1);
    # A rate limit waits what GitHub says, or not at all.
    testing.assertEqual(retryWaitMs(429, {"retry-after": "3"}, 0, $now), 3000);
    testing.assertEqual(retryWaitMs(429, {}, 0, $now), -1);
    testing.assertEqual(
        retryWaitMs(403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1010"}, 0, $now),
        11000);
    testing.assertEqual(
        retryWaitMs(403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "5000"}, 0, $now),
        -1);
    # A plain 403 or 404 is an answer, not a hiccup.
    testing.assertEqual(retryWaitMs(403, {}, 0, $now), -1);
    testing.assertEqual(retryWaitMs(404, {}, 0, $now), -1);
    testing.assertEqual(secondsOf("12"), 12);
    testing.assertEqual(secondsOf("1.5"), -1);
    testing.assertEqual(idleMs(client("x")), 30000);
    testing.assertEqual(idleMs(withTimeout(client("x"), 500)), 500);
}

func testCallSendsTheHeaders() {
    def f as Fake init fake([
        ok('{"id":1,"login":"me","name":"Me","site_admin":true}'),
        ok('{"resources":{"core":{"limit":5000,"remaining":4990,"used":10,"reset":1800000000}}}')
    ]);
    def c as Client init tokenClient($f);
    def u as User init currentUser($c);
    def rl as RateLimit init rateLimit($c);
    def seen as list of Seen init finish($f);
    testing.assertEqual($u.login, "me");
    testing.assertEqual($u.name, "Me");
    testing.assertTrue($u.isAdmin);
    testing.assertEqual($rl.remaining, 4990);
    testing.assertEqual($rl.reset, 1800000000);
    testing.assertEqual($seen[0].method, "GET");
    testing.assertEqual($seen[0].path, "/api/v3/user");
    testing.assertEqual($seen[0].auth, "Bearer t0k3n");
    testing.assertEqual($seen[0].accept, "application/vnd.github+json");
    testing.assertEqual($seen[0].version, "2022-11-28");
    testing.assertEqual($seen[0].agent, USER_AGENT);
    testing.assertEqual($seen[1].path, "/api/v3/rate_limit");
}

func testAnonymousSendsNoToken() {
    def f as Fake init fake([ok(REPO)]);
    repository(client($f.url), "me/app");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].auth, "");
    testing.assertEqual($seen[0].agent, USER_AGENT);
}

func testRefusalsNameTheRequest() {
    def f as Fake init fake([answer(404, '{"message":"Not Found"}')]);
    try {
        repository(tokenClient($f), "me/missing");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: GET /repos/me/missing: HTTP 404: Not Found");
        # the status is a field: no need to read it out of the message
        testing.assertEqual($e.status, 404);
    }
    finish($f);
    try {
        call(client("x"), "TRACE", "/user", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "unsupported method");
    }
}

func testRateLimitFailsAtOnce() {
    # The reset is far off: no retry, the limit in the message and the status.
    def f as Fake init fake([
        Reply{
            status: 403,
            headers: {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "4000000000"},
            body: '{"message":"API rate limit exceeded for 1.2.3.4."}'
        }
    ]);
    try {
        repository(withRetries(tokenClient($f), 3), "me/app");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "[rate limit exhausted; resets at 2096-");
        testing.assertEqual($e.status, 403);
    }
    testing.assertEqual(len(finish($f)), 1);
}

func testGetRetriesAStatedWait() {
    def f as Fake init fake([
        Reply{status: 429, headers: {"Retry-After": "0"}, body: '{"message":"slow down"}'},
        ok(REPO)
    ]);
    testing.assertEqual(repository(withRetries(tokenClient($f), 1), "me/app").name, "app");
    testing.assertEqual(len(finish($f)), 2);
}

func testWritesAreNotRetried() {
    def f as Fake init fake([Reply{status: 429, headers: {"Retry-After": "0"}, body: ""}]);
    try {
        createIssue(withRetries(tokenClient($f), 3), "me/app", "x", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 429);
    }
    testing.assertEqual(len(finish($f)), 1);
}

func testGetAllFollowsTheLink() {
    def f as Fake init fake([
        pageOf(entries(100), "BASE/api/v3/repositories/7/issues?state=open&per_page=100&page=2"),
        ok(entries(3))
    ]);
    def got as list of json.Value init getAll(tokenClient($f), "/repos/me/app/issues?state=open");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($got), 103);
    testing.assertEqual($seen[0].query, "state=open&per_page=100");
    testing.assertEqual($seen[1].path, "/api/v3/repositories/7/issues");
    testing.assertEqual($seen[1].query, "state=open&per_page=100&page=2");
    testing.assertEqual($seen[1].auth, "Bearer t0k3n");
}

func testGetAllKeepsAGivenPageSize() {
    def f as Fake init fake([ok(entries(2))]);
    getAll(tokenClient($f), "/repos/me/app/labels?per_page=10");
    testing.assertEqual(finish($f)[0].query, "per_page=10");
}

func testGetAllRefusesAForeignNextPage() {
    def f as Fake init fake([pageOf(entries(1), "https://evil.example.com/api/v3/x?page=2&sig=s")]);
    try {
        getAll(tokenClient($f), "/user/repos");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the next page is not under");
        testing.assertContains(messageOf($e), "evil.example.com/api/v3/x");
        testing.assertFalse(strings.contains(messageOf($e), "sig=s"));
    }
    testing.assertEqual(len(finish($f)), 1);
}

func testGetAllUnwrapsOneList() {
    def f as Fake init fake([
        ok('{"total_count":2,"incomplete_results":false,"items":' + entries(2) + '}'),
        ok('{"a":[],"b":[]}'),
        ok('{"not":"a list"}')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(len(getAll($c, "/search/code?q=x")), 2);
    for (def path in ["/a", "/b"]) {
        try {
            getAll($c, $path);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "neither a list nor an object holding one list");
        }
    }
    finish($f);
}

func testLinkHeader() {
    def c as Client init client("github.com");
    testing.assertEqual(
        nextPath(
            $c,
            '<https://api.github.com/user/repos?page=3>; rel="next", ' +
                '<https://api.github.com/user/repos?page=1>; rel="prev"',
            "GET /user/repos"),
        "/user/repos?page=3");
    testing.assertEqual(
        nextPath($c, '<https://api.github.com/user/repos?page=1>; rel="prev"', "x"),
        "");
    testing.assertEqual(nextPath($c, "", "x"), "");
    # A host that only starts like the API's is another host.
    try {
        nextPath($c, '<https://api.github.com.evil.io/x>; rel="next"', "GET /x");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the next page is not under https://api.github.com");
    }
}

func testRepositories() {
    def f as Fake init fake([
        ok(REPO),
        ok("[" + REPO + "]"),
        Reply{status: 201, headers: {}, body: REPO},
        Reply{status: 201, headers: {}, body: REPO},
        answer(204, ""),
        ok("[" + REPO + "," + REPO + "]"),
        ok('{"total_count":1,"incomplete_results":false,"items":[' + REPO + ']}')
    ]);
    def c as Client init tokenClient($f);
    def r as Repository init repository($c, "me/app");
    testing.assertEqual($r.fullName, "me/app");
    testing.assertEqual($r.owner, "me");
    testing.assertTrue($r.isPrivate);
    testing.assertEqual($r.defaultBranch, "main");
    testing.assertEqual($r.sshUrl, "git@github.com:me/app.git");
    testing.assertEqual($r.stars, 3);
    testing.assertEqual($r.openIssues, 2);
    testing.assertEqual(len(repositories($c, "me")), 1);
    createRepository($c, "", "app", "An app", true);
    createRepository($c, "acme", "app", "", false);
    deleteRepository($c, "me/app");
    testing.assertEqual(len(myRepositories($c)), 2);
    testing.assertEqual(searchRepositories($c, "jennifer language:go")[0].name, "app");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[1].path, "/api/v3/users/me/repos");
    testing.assertEqual($seen[2].method, "POST");
    testing.assertEqual($seen[2].path, "/api/v3/user/repos");
    testing.assertEqual($seen[2].contentType, "application/json");
    testing.assertEqual(bodyOf($seen[2]), '{"description":"An app","name":"app","private":true}');
    testing.assertEqual($seen[3].path, "/api/v3/orgs/acme/repos");
    testing.assertEqual(bodyOf($seen[3]), '{"name":"app","private":false}');
    testing.assertEqual($seen[4].method, "DELETE");
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app");
    testing.assertEqual($seen[5].path, "/api/v3/user/repos");
    testing.assertEqual($seen[6].path, "/api/v3/search/repositories");
    testing.assertEqual($seen[6].query, "q=jennifer%20language%3Ago&per_page=100");
}

func testRepositoryAdmin() {
    def hook as string init '{"id":2,"type":"Repository","name":"web","config":{"url":"https://ci/hook",' +
        '"content_type":"json"},"events":["push"],"active":true}';
    def f as Fake init fake([
        ok(REPO),
        ok(REPO),
        ok(REPO),
        Reply{status: 202, headers: {}, body: REPO},
        ok("[" + $hook + "]"),
        Reply{status: 201, headers: {}, body: $hook},
        answer(204, ""),
        ok('[{"id":3,"login":"ada"}]'),
        Reply{status: 201, headers: {}, body: '{"id":1}'},
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    editRepository($c, "me/app", "An app", "https://app.example.com");
    setArchived($c, "me/app", true);
    setDefaultBranch($c, "me/app", "trunk");
    testing.assertEqual(forkRepository($c, "octo/app", "", "my-app").name, "app");
    testing.assertEqual(hooks($c, "me/app")[0].url, "https://ci/hook");
    def h as Hook init createHook($c, "me/app", "https://ci/hook", "s", ["push"]);
    testing.assertEqual($h.name, "web");
    deleteHook($c, "me/app", 2);
    testing.assertEqual(collaborators($c, "me/app")[0].login, "ada");
    addCollaborator($c, "me/app", "ada", "push");
    removeCollaborator($c, "me/app", "ada");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "PATCH");
    testing.assertEqual(
        bodyOf($seen[0]),
        '{"description":"An app","homepage":"https://app.example.com"}');
    testing.assertEqual(bodyOf($seen[1]), '{"archived":true}');
    testing.assertEqual(bodyOf($seen[2]), '{"default_branch":"trunk"}');
    testing.assertEqual($seen[3].path, "/api/v3/repos/octo/app/forks");
    testing.assertEqual(bodyOf($seen[3]), '{"name":"my-app"}');
    testing.assertEqual(
        bodyOf($seen[5]),
        '{"name":"web","active":true,"config":{"content_type":"json","secret":"s",' +
            '"url":"https://ci/hook"},"events":["push"]}');
    testing.assertEqual($seen[6].path, "/api/v3/repos/me/app/hooks/2");
    testing.assertEqual($seen[8].method, "PUT");
    testing.assertEqual($seen[8].path, "/api/v3/repos/me/app/collaborators/ada");
    testing.assertEqual(bodyOf($seen[8]), '{"permission":"push"}');
    testing.assertEqual($seen[9].method, "DELETE");
    try {
        createHook($c, "me/app", "ftp://x", "", ["push"]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a webhook URL is http");
    }
    try {
        addCollaborator($c, "me/app", "ada", "write");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a permission is one of pull, triage, push");
    }
}

func testIssues() {
    def f as Fake init fake([
        ok("[" + ISSUE + "," + PULL_ISSUE + "]"),
        ok(ISSUE),
        Reply{status: 201, headers: {}, body: ISSUE},
        ok(ISSUE),
        ok(ISSUE),
        Reply{status: 201, headers: {}, body: '{"id":99,"user":{"login":"me"},"body":"On it"}'},
        ok('[{"id":1,"user":{"login":"ada"},"body":"first"}]'),
        ok('{"total_count":2,"items":[' + ISSUE + "," + PULL_ISSUE + ']}')
    ]);
    def c as Client init tokenClient($f);
    def got as list of Issue init issues($c, "me/app", "open");
    testing.assertEqual(len($got), 1);
    testing.assertEqual($got[0].number, 12);
    testing.assertEqual($got[0].author, "ada");
    testing.assertEqual($got[0].labels, ["bug", "p1"]);
    testing.assertEqual($got[0].assignees, ["bob"]);
    testing.assertFalse($got[0].isPull);
    testing.assertEqual($got[0].closed, "");
    testing.assertEqual(issue($c, "me/app", 12).title, "Crash on start");
    createIssue($c, "me/app", "Crash on start", "");
    closeIssue($c, "me/app", 12);
    reopenIssue($c, "me/app", 12);
    testing.assertEqual(comment($c, "me/app", 12, "On it").id, 99);
    testing.assertEqual(comments($c, "me/app", 12)[0].body, "first");
    def found as list of Issue init searchIssues($c, "repo:me/app is:open");
    testing.assertTrue($found[1].isPull);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v3/repos/me/app/issues");
    testing.assertEqual($seen[0].query, "state=open&per_page=100");
    testing.assertEqual($seen[1].path, "/api/v3/repos/me/app/issues/12");
    testing.assertEqual(bodyOf($seen[2]), '{"title":"Crash on start"}');
    testing.assertEqual($seen[3].method, "PATCH");
    testing.assertEqual(bodyOf($seen[3]), '{"state":"closed"}');
    testing.assertEqual(bodyOf($seen[4]), '{"state":"open"}');
    testing.assertEqual($seen[5].path, "/api/v3/repos/me/app/issues/12/comments");
    testing.assertEqual(bodyOf($seen[5]), '{"body":"On it"}');
    testing.assertEqual($seen[7].query, "q=repo%3Ame%2Fapp%20is%3Aopen&per_page=100");
    try {
        issues($c, "me/app", "opened");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a state is open, closed or all");
    }
    try {
        createIssue($c, "me/app", " ", "x");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: an issue needs a title");
    }
    try {
        searchIssues($c, " ");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a search needs a query");
    }
}

func testEditing() {
    def f as Fake init fake([
        ok(ISSUE),
        ok(ISSUE),
        ok(ISSUE),
        ok(ISSUE),
        ok('{"id":9,"body":"better","user":{"login":"me"}}'),
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    editIssue($c, "me/app", 12, "Crash on start", "");
    setAssignees($c, "me/app", 12, ["bob", "ada"]);
    setMilestone($c, "me/app", 12, 3);
    setMilestone($c, "me/app", 12, 0);
    testing.assertEqual(editComment($c, "me/app", 9, "better").body, "better");
    deleteComment($c, "me/app", 9);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "PATCH");
    testing.assertEqual(bodyOf($seen[0]), '{"title":"Crash on start"}');
    testing.assertEqual(bodyOf($seen[1]), '{"assignees":["bob","ada"]}');
    testing.assertEqual(bodyOf($seen[2]), '{"milestone":3}');
    testing.assertEqual(bodyOf($seen[3]), '{"milestone":null}');
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app/issues/comments/9");
    testing.assertEqual($seen[5].method, "DELETE");
}

func testLabelsAndMilestones() {
    def label as string init '{"id":4,"name":"bug","color":"d73a4a","description":"",' +
        '"default":true}';
    def milestone as string init '{"id":30,"number":3,"title":"1.0","state":"open",' +
        '"due_on":null,"open_issues":2,"closed_issues":5}';
    def f as Fake init fake([
        ok("[" + $label + "]"),
        Reply{status: 201, headers: {}, body: $label},
        answer(204, ""),
        ok("[" + $label + "]"),
        ok("[" + $label + "]"),
        ok("[]"),
        ok("[" + $milestone + "]"),
        Reply{status: 201, headers: {}, body: $milestone},
        ok($milestone),
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    def first as Label init labels($c, "me/app")[0];
    testing.assertEqual($first.name, "bug");
    testing.assertEqual($first.color, "#d73a4a");
    testing.assertTrue($first.isDefault);
    testing.assertEqual(createLabel($c, "me/app", "bug", "#d73a4a", "").id, 4);
    deleteLabel($c, "me/app", "good first issue");
    testing.assertEqual(len(setIssueLabels($c, "me/app", 12, ["bug"])), 1);
    addIssueLabels($c, "me/app", 12, ["bug"]);
    removeIssueLabel($c, "me/app", 12, "scope/ui");
    def ms as list of Milestone init milestones($c, "me/app", "open");
    createMilestone($c, "me/app", "1.0", "", "2026-12-31T00:00:00Z");
    setMilestoneClosed($c, "me/app", 3, true);
    deleteMilestone($c, "me/app", 3);
    def seen as list of Seen init finish($f);
    testing.assertEqual($ms[0].number, 3);
    testing.assertEqual($ms[0].closedIssues, 5);
    testing.assertEqual($ms[0].dueOn, "");
    testing.assertEqual(bodyOf($seen[1]), '{"color":"d73a4a","name":"bug"}');
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/labels/good first issue");
    testing.assertEqual($seen[3].method, "PUT");
    testing.assertEqual(bodyOf($seen[3]), '{"labels":["bug"]}');
    testing.assertEqual($seen[4].method, "POST");
    # The label is one segment: its / is encoded, and httpd decodes it once.
    testing.assertEqual($seen[5].path, "/api/v3/repos/me/app/issues/12/labels/scope/ui");
    testing.assertEqual($seen[6].query, "state=open&per_page=100");
    testing.assertEqual(bodyOf($seen[7]), '{"due_on":"2026-12-31T00:00:00Z","title":"1.0"}');
    testing.assertEqual($seen[8].path, "/api/v3/repos/me/app/milestones/3");
    testing.assertEqual(bodyOf($seen[8]), '{"state":"closed"}');
    try {
        createLabel($c, "me/app", "bug", "red", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a label colour is #rrggbb");
    }
}

func testPullRequests() {
    def f as Fake init fake([
        ok("[" + PULL + "]"),
        ok(PULL),
        Reply{status: 201, headers: {}, body: PULL},
        ok(PULL),
        ok('{"sha":"m1","merged":true,"message":"Pull Request successfully merged"}'),
        answer(204, ""),
        ok('{"merged":true}'),
        ok(PULL)
    ]);
    def c as Client init tokenClient($f);
    def got as list of PullRequest init pullRequests($c, "me/app", "all");
    testing.assertEqual($got[0].head, "fix-crash");
    testing.assertEqual($got[0].base, "main");
    testing.assertEqual($got[0].headSha, "abc123");
    testing.assertTrue($got[0].mergeable);
    testing.assertFalse($got[0].merged);
    testing.assertEqual($got[0].mergeSha, "");
    testing.assertEqual(pullRequest($c, "me/app", 15).number, 15);
    createPullRequest($c, "me/app", "fix-crash", "main", "Fix crash", "Fixes #12");
    # The head is in this repository: it is deleted after the merge.
    mergePullRequest($c, "me/app", 15, "squash", true);
    mergePullRequest($c, "me/app", 15, "rebase", false);
    editPullRequest($c, "me/app", 15, "", "New text");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].query, "state=all&per_page=100");
    testing.assertEqual(
        bodyOf($seen[2]),
        '{"base":"main","body":"Fixes #12","head":"fix-crash","title":"Fix crash"}');
    testing.assertEqual($seen[3].method, "GET");
    testing.assertEqual($seen[4].method, "PUT");
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app/pulls/15/merge");
    testing.assertEqual(bodyOf($seen[4]), '{"merge_method":"squash"}');
    testing.assertEqual($seen[5].method, "DELETE");
    testing.assertEqual($seen[5].path, "/api/v3/repos/me/app/git/refs/heads/fix-crash");
    testing.assertEqual(bodyOf($seen[6]), '{"merge_method":"rebase"}');
    testing.assertEqual($seen[7].method, "PATCH");
    testing.assertEqual(bodyOf($seen[7]), '{"body":"New text"}');
    try {
        mergePullRequest($c, "me/app", 15, "fast-forward-only", false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a merge style is one of merge, squash, rebase");
    }
}

func testMergeAfterGithubDeletedTheBranch() {
    def gone as string init '{"message":"Reference does not exist","status":"422"}';
    def f as Fake init fake([
        # GitHub deleted the branch itself: the 422 is checked and ignored
        ok(PULL),
        ok('{"merged":true}'),
        answer(422, $gone),
        answer(404, '{"message":"Not Found","status":"404"}'),
        # a 422 for a branch that is still there is a failure
        ok(PULL),
        ok('{"merged":true}'),
        answer(422, '{"message":"Cannot delete this branch","status":"422"}'),
        ok('{"ref":"refs/heads/fix-crash","object":{"sha":"abc123"}}'),
        # any other refusal is a failure without the check
        ok(PULL),
        ok('{"merged":true}'),
        answer(403, '{"message":"Resource not accessible by integration","status":"403"}')
    ]);
    def c as Client init tokenClient($f);
    mergePullRequest($c, "me/app", 15, "squash", true);
    try {
        mergePullRequest($c, "me/app", 15, "squash", true);
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 422);
        testing.assertTrue(strings.startsWith(
            messageOf($e),
            'github: merged #15, but deleting branch "fix-crash" failed: DELETE '));
    }
    try {
        mergePullRequest($c, "me/app", 15, "squash", true);
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 403);
        testing.assertContains(messageOf($e), "merged #15, but deleting branch");
        testing.assertContains(messageOf($e), "Resource not accessible by integration");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 11);
    testing.assertEqual($seen[3].method, "GET");
    testing.assertEqual($seen[3].path, "/api/v3/repos/me/app/git/ref/heads/fix-crash");
    testing.assertEqual($seen[10].method, "DELETE");
}

func testMergeLeavesAForksBranch() {
    def fork as string init strings.replace(PULL, "Me/App", "someone/app");
    def f as Fake init fake([ok($fork), ok('{"merged":true}')]);
    mergePullRequest(tokenClient($f), "me/app", 15, "merge", true);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 2);
}

func testReviews() {
    def review as string init '{"id":8,"user":{"login":"bob"},"state":"APPROVED","body":"",' +
        '"commit_id":"abc","submitted_at":"t"}';
    def f as Fake init fake([
        ok($review),
        ok("[" + $review + "]"),
        Reply{status: 201, headers: {}, body: PULL},
        ok('[{"filename":"src/a.j","status":"modified","additions":3,"deletions":1}]')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(reviewPullRequest($c, "me/app", 15, "APPROVE", "").state, "APPROVED");
    testing.assertEqual(reviews($c, "me/app", 15)[0].author, "bob");
    requestReviewers($c, "me/app", 15, ["ada"]);
    def files as list of ChangedFile init pullRequestFiles($c, "me/app", 15);
    def seen as list of Seen init finish($f);
    testing.assertEqual($files[0].additions, 3);
    testing.assertEqual($seen[0].path, "/api/v3/repos/me/app/pulls/15/reviews");
    testing.assertEqual(bodyOf($seen[0]), '{"event":"APPROVE"}');
    testing.assertEqual(bodyOf($seen[2]), '{"reviewers":["ada"]}');
    testing.assertEqual($seen[3].path, "/api/v3/repos/me/app/pulls/15/files");
    try {
        reviewPullRequest($c, "me/app", 15, "REQUEST_CHANGES", " ");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "review needs a text");
    }
    try {
        reviewPullRequest($c, "me/app", 15, "APPROVED", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a review is APPROVE");
    }
}

func testReleases() {
    def rel as string init '{"id":5,"tag_name":"1.2.0","name":"1.2.0","body":"Notes",' +
        '"draft":false,"prerelease":true,"created_at":"c","published_at":"p","html_url":"h",' +
        '"assets":[{"id":9,"name":"app.tar.gz","content_type":"application/gzip","size":1234,' +
        '"download_count":7,"browser_download_url":"https://github.com/me/app/releases/' +
        'download/1.2.0/app.tar.gz","url":"https://api.github.com/repos/me/app/releases/assets/9"}]}';
    def f as Fake init fake([
        ok("[" + $rel + "]"),
        ok($rel),
        ok($rel),
        Reply{status: 201, headers: {}, body: $rel},
        ok($rel),
        answer(204, ""),
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    def got as list of Release init releases($c, "me/app");
    testing.assertEqual($got[0].tag, "1.2.0");
    testing.assertTrue($got[0].isPrerelease);
    testing.assertEqual($got[0].assets[0].name, "app.tar.gz");
    testing.assertEqual($got[0].assets[0].contentType, "application/gzip");
    testing.assertEqual($got[0].assets[0].size, 1234);
    testing.assertEqual($got[0].assets[0].downloads, 7);
    testing.assertEqual(release($c, "me/app", "release/1.2").id, 5);
    testing.assertEqual(latestRelease($c, "me/app").tag, "1.2.0");
    createRelease($c, "me/app", "1.2.0", "", "", "Notes", true);
    testing.assertEqual(editRelease($c, "me/app", 5, "Final", "").id, 5);
    deleteRelease($c, "me/app", 5);
    deleteAsset($c, "me/app", 9);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[1].path, "/api/v3/repos/me/app/releases/tags/release/1.2");
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/releases/latest");
    testing.assertEqual(
        bodyOf($seen[3]),
        '{"body":"Notes","tag_name":"1.2.0","draft":false,"prerelease":true}');
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app/releases/5");
    testing.assertEqual(bodyOf($seen[4]), '{"name":"Final"}');
    testing.assertEqual($seen[5].path, "/api/v3/repos/me/app/releases/5");
    testing.assertEqual($seen[6].path, "/api/v3/repos/me/app/releases/assets/9");
}

func testUploadAsset() {
    def f as Fake init fake([
        Reply{status: 201, headers: {}, body: '{"id":10,"name":"app 1.zip","size":3}'},
        answer(422, '{"message":"Validation Failed","errors":[{"code":"already_exists"}]}')
    ]);
    def c as Client init tokenClient($f);
    def a as Asset init uploadAsset(
        $c,
        "me/app",
        5,
        "app 1.zip",
        convert.bytesFromString("utf-8", "zip"));
    testing.assertEqual($a.id, 10);
    try {
        uploadAsset($c, "me/app", 5, "app 1.zip", convert.bytesFromString("utf-8", "zip"));
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 422);
        testing.assertContains(messageOf($e), "already_exists");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api/uploads/repos/me/app/releases/5/assets");
    testing.assertEqual($seen[0].query, "name=app%201.zip");
    testing.assertEqual($seen[0].contentType, "application/octet-stream");
    testing.assertEqual($seen[0].auth, "Bearer t0k3n");
    testing.assertEqual(convert.stringFromBytes("utf-8", $seen[0].body), "zip");
    try {
        uploadAsset($c, "me/app", 5, "a/b", convert.bytesFromString("utf-8", "x"));
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an asset name holds no /");
    }
}

func testDownloadAssetDropsTheTokenOnRedirect() {
    def storage as Fake init fake([ok("BINARY")]);
    def api as Fake init fake([
        Reply{
            status: 302,
            headers: {"Location": $storage.url + "/blob/9?X-Amz-Signature=s3cr3t"},
            body: ""
        }
    ]);
    def c as Client init tokenClient($api);
    def a as Asset;
    $a.name = "app.tar.gz";
    $a.apiUrl = $c.url + "/repos/me/app/releases/assets/9";
    testing.assertEqual(convert.stringFromBytes("utf-8", downloadAsset($c, $a, 0)), "BINARY");
    def asked as list of Seen init finish($api);
    def fetched as list of Seen init finish($storage);
    testing.assertEqual($asked[0].path, "/api/v3/repos/me/app/releases/assets/9");
    testing.assertEqual($asked[0].accept, "application/octet-stream");
    testing.assertEqual($asked[0].auth, "Bearer t0k3n");
    testing.assertEqual($fetched[0].path, "/blob/9");
    testing.assertEqual($fetched[0].query, "X-Amz-Signature=s3cr3t");
    testing.assertEqual($fetched[0].auth, "");
    testing.assertEqual($fetched[0].version, "");
}

func testDownloadAssetChecks() {
    def c as Client init withToken(client("github.com"), "t0k3n");
    def a as Asset;
    $a.name = "x";
    $a.apiUrl = "https://evil.example.com/repos/me/app/releases/assets/9";
    try {
        downloadAsset($c, $a, 0);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is not on https://api.github.com");
    }
    # The storage host refuses: its status, but not the signed query, in the message.
    def storage as Fake init fake([answer(403, "<Error>expired</Error>")]);
    def api as Fake init fake([
        Reply{status: 302, headers: {"Location": $storage.url + "/blob/9?sig=s3cr3t"}, body: ""}
    ]);
    def d as Client init tokenClient($api);
    $a.apiUrl = $d.url + "/repos/me/app/releases/assets/9";
    try {
        downloadAsset($d, $a, 0);
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 403);
        testing.assertFalse(strings.contains(messageOf($e), "s3cr3t"));
    }
    finish($api);
    finish($storage);
    # A body over the cap is kind "limit".
    def big as Fake init fake([ok(strings.repeat("x", 100))]);
    def b as Client init tokenClient($big);
    $a.apiUrl = $b.url + "/repos/me/app/releases/assets/9";
    try {
        downloadAsset($b, $a, 10);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "github: GET ");
    }
    finish($big);
}

func testBranchesAndTags() {
    def f as Fake init fake([
        ok('[{"name":"main","commit":{"sha":"aaa"},"protected":true}]'),
        ok('[{"name":"1.0.0","commit":{"sha":"bbb"},"zipball_url":"z"}]'),
        ok('{"sha":"ccc"}'),
        Reply{
            status: 201,
            headers: {},
            body: '{"ref":"refs/heads/feature","object":{"sha":"ccc"}}'
        },
        ok(REPO),
        ok('{"sha":"ddd"}'),
        Reply{status: 201, headers: {}, body: '{"ref":"refs/heads/hotfix","object":{"sha":"ddd"}}'},
        answer(204, ""),
        Reply{status: 201, headers: {}, body: '{"sha":"tagobj"}'},
        Reply{status: 201, headers: {}, body: '{"ref":"refs/tags/1.2.0"}'},
        Reply{status: 201, headers: {}, body: '{"ref":"refs/tags/light"}'},
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    def b as list of Branch init branches($c, "me/app");
    def t as list of Tag init tags($c, "me/app");
    testing.assertEqual($b[0].sha, "aaa");
    testing.assertTrue($b[0].isProtected);
    testing.assertEqual($t[0].name, "1.0.0");
    testing.assertEqual($t[0].sha, "bbb");
    testing.assertEqual(createBranch($c, "me/app", "feature", "main").sha, "ccc");
    testing.assertEqual(createBranch($c, "me/app", "hotfix", "").sha, "ddd");
    deleteBranch($c, "me/app", "feature/x");
    def made as Tag init createTag($c, "me/app", "1.2.0", SHA, "Release 1.2.0");
    testing.assertEqual($made.sha, SHA);
    testing.assertEqual($made.message, "Release 1.2.0");
    createTag($c, "me/app", "light", SHA, "");
    deleteTag($c, "me/app", "1.2.0");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/commits/main");
    testing.assertEqual($seen[3].path, "/api/v3/repos/me/app/git/refs");
    testing.assertEqual(bodyOf($seen[3]), '{"ref":"refs/heads/feature","sha":"ccc"}');
    # "" starts at the default branch, read from the repository.
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app");
    testing.assertEqual($seen[5].path, "/api/v3/repos/me/app/commits/main");
    testing.assertEqual($seen[7].method, "DELETE");
    testing.assertEqual($seen[7].path, "/api/v3/repos/me/app/git/refs/heads/feature/x");
    testing.assertEqual($seen[8].path, "/api/v3/repos/me/app/git/tags");
    testing.assertEqual(
        bodyOf($seen[8]),
        '{"message":"Release 1.2.0","object":"' + SHA + '","tag":"1.2.0","type":"commit"}');
    testing.assertEqual(bodyOf($seen[9]), '{"ref":"refs/tags/1.2.0","sha":"tagobj"}');
    testing.assertEqual(bodyOf($seen[10]), '{"ref":"refs/tags/light","sha":"' + SHA + '"}');
    testing.assertEqual($seen[11].path, "/api/v3/repos/me/app/git/refs/tags/1.2.0");
}

func testFiles() {
    def f as Fake init fake([
        Reply{
            status: 200,
            headers: {"Content-Type": "application/vnd.github.raw+json; charset=utf-8"},
            body: "hello"
        },
        answer(404, '{"message":"Not Found"}'),
        Reply{status: 201, headers: {}, body: '{"content":{"sha":"blob1"},"commit":{"sha":"c1"}}'},
        ok('{"sha":"blob1","type":"file"}'),
        ok('{"content":{"sha":"blob2"},"commit":{"sha":"c2"}}'),
        answer(502, '{"message":"Server Error"}'),
        ok('{"sha":"blob2","type":"file"}'),
        ok('{"content":null,"commit":{"sha":"c3"}}'),
        ok('[{"name":"README.md","path":"README.md","type":"file","size":12,"sha":"b1"},' +
            '{"name":"src","path":"src","type":"dir","size":0,"sha":"t1"}]'),
        ok('{"name":"README.md","type":"file"}')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(
        convert.stringFromBytes("utf-8", readFile($c, "me/app", "docs/a b.md", "dev")),
        "hello");
    def data as bytes init convert.bytesFromString("utf-8", "hello");
    testing.assertEqual(writeFile($c, "me/app", "data/v.txt", $data, "add v", ""), "c1");
    testing.assertEqual(writeFile($c, "me/app", "data/v.txt", $data, "bump v", "dev"), "c2");
    # Only a 404 for the file itself means create; this one is no 404.
    try {
        writeFile($c, "me/app", "data/v.txt", $data, "bump v", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 502);
    }
    testing.assertEqual(deleteFile($c, "me/app", "data/v.txt", "remove v", "dev"), "c3");
    def dir as list of Entry init listDirectory($c, "me/app", "", "main");
    testing.assertEqual($dir[1].type, "dir");
    testing.assertEqual($dir[0].size, 12);
    try {
        listDirectory($c, "me/app", "README.md", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is not a directory");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v3/repos/me/app/contents/docs/a b.md");
    testing.assertEqual($seen[0].query, "ref=dev");
    testing.assertEqual($seen[0].accept, "application/vnd.github.raw+json");
    testing.assertEqual($seen[1].method, "GET");
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/contents/data/v.txt");
    testing.assertEqual(bodyOf($seen[2]), '{"message":"add v","content":"aGVsbG8="}');
    testing.assertEqual($seen[3].query, "ref=dev");
    testing.assertEqual(
        bodyOf($seen[4]),
        '{"branch":"dev","message":"bump v","sha":"blob1","content":"aGVsbG8="}');
    testing.assertEqual($seen[7].method, "DELETE");
    testing.assertEqual(bodyOf($seen[7]), '{"branch":"dev","message":"remove v","sha":"blob2"}');
    testing.assertEqual($seen[8].path, "/api/v3/repos/me/app/contents");
    testing.assertEqual($seen[8].query, "ref=main");
    try {
        writeFile($c, "me/app", "x", $data, " ", "");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a commit needs a message");
    }
}

# A directory ignores the raw media type and answers its JSON listing: that
# is no file content.
func testReadFileRefusesADirectory() {
    def f as Fake init fake([
        ok('[{"name":"a.go","path":"pkg/a.go","type":"file"}]'),
        Reply{
            status: 200,
            headers: {"Content-Type": "application/vnd.github.raw+json; charset=utf-8"},
            body: '{"a":1}'
        }
    ]);
    def c as Client init tokenClient($f);
    try {
        readFile($c, "me/app", "pkg", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 0);
        testing.assertEqual(
            messageOf($e),
            "github: GET " + $f.url + "/api/v3/repos/me/app/contents/pkg: \"pkg\" is not a file");
    }
    # A JSON file is still a file: its media type is the raw one.
    testing.assertEqual(
        convert.stringFromBytes("utf-8", readFile($c, "me/app", "data.json", "")),
        '{"a":1}');
    finish($f);
}

# GitHub requires `content` even for an empty file.
func testWriteFileOfAnEmptyFile() {
    def f as Fake init fake([
        answer(404, '{"message":"Not Found"}'),
        Reply{status: 201, headers: {}, body: '{"content":{"sha":"e1"},"commit":{"sha":"c0"}}'}
    ]);
    def empty as bytes init convert.bytesFromString("utf-8", "");
    testing.assertEqual(
        writeFile(tokenClient($f), "me/app", ".keep", $empty, "add .keep", ""),
        "c0");
    testing.assertEqual(bodyOf(finish($f)[1]), '{"message":"add .keep","content":""}');
}

# A ref goes into a query string, but is checked like one in a path: no
# control characters, no empty, . or .. segments.
func testRefsAreChecked() {
    def c as Client init client("x");
    for (def bad in ["a\nb", "a/../b", "a//b"]) {
        try {
            readFile($c, "me/app", "README.md", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a ref ");
        }
        try {
            listDirectory($c, "me/app", "", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a ref ");
        }
        try {
            writeFile($c, "me/app", "a.txt", convert.bytesFromString("utf-8", "x"), "m", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a branch ");
        }
    }
}

# github.com reports the dispatched run only when asked; an Enterprise Server
# knows no such member. An input given as "" is sent, not dropped.
func testDispatchBody() {
    testing.assertEqual(
        dispatchBody(client("github.com"), "main", {"level": "", "a/b": "1"}),
        '{"ref":"main","inputs":{"a/b":"1","level":""},"return_run_details":true}');
    testing.assertEqual(
        dispatchBody(client("ghe.example.com"), "v1", {}),
        '{"ref":"v1","inputs":{}}');
    try {
        dispatchBody(client("github.com"), "main", {"": "x"});
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a workflow input has a name");
    }
    try {
        dispatchBody(client("github.com"), "", {});
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a workflow runs on a ref");
    }
}

func testDeleteFileOfAMissingFile() {
    def f as Fake init fake([answer(404, '{"message":"Not Found"}')]);
    try {
        deleteFile(tokenClient($f), "me/app", "gone.txt", "rm", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 404);
        testing.assertContains(messageOf($e), "is not a file");
    }
    finish($f);
}

func testCommitsAndStatuses() {
    def one as string init '{"sha":"abc","html_url":"h","commit":{"message":"Fix it",' +
        '"author":{"name":"Ada","email":"ada@example.com","date":"2026-11-01T10:00:00Z"}}}';
    def status as string init '{"context":"ci/build","state":"success","description":"ok",' +
        '"target_url":"https://ci/1","creator":{"login":"bot"},"created_at":"t"}';
    def f as Fake init fake([
        ok("[" + $one + "]"),
        ok($one),
        Reply{status: 201, headers: {}, body: $status},
        ok("[" + $status + "]"),
        pageOf(
            '{"state":"failure","total_count":2,"statuses":[' + $status + ']}',
            "BASE/api/v3/repositories/7/commits/main/status?page=2"),
        ok('{"state":"failure","total_count":2,"statuses":[' + $status + ']}'),
        ok('{"total_count":1,"check_runs":[{"id":4,"name":"build","status":"completed",' +
            '"conclusion":"success","html_url":"h","started_at":"s","completed_at":"e"}]}')
    ]);
    def c as Client init tokenClient($f);
    def all as list of Commit init commits($c, "me/app", "dev", "src");
    def single as Commit init commit($c, "me/app", "feature/a b");
    def made as CommitStatus init setCommitStatus(
        $c,
        "me/app",
        "abc123",
        "success",
        "ci/build",
        "ok",
        "https://ci/1");
    def history as list of CommitStatus init commitStatuses($c, "me/app", "main");
    def combined as CombinedStatus init combinedStatus($c, "me/app", "main");
    def runs as list of CheckRun init checkRuns($c, "me/app", "main");
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].message, "Fix it");
    testing.assertEqual($all[0].authorEmail, "ada@example.com");
    testing.assertEqual($single.date, "2026-11-01T10:00:00Z");
    testing.assertEqual($made.state, "success");
    testing.assertEqual($made.creator, "bot");
    testing.assertEqual($history[0].targetUrl, "https://ci/1");
    testing.assertEqual($combined.state, "failure");
    testing.assertEqual(len($combined.statuses), 2);
    testing.assertEqual($runs[0].conclusion, "success");
    testing.assertEqual($seen[0].query, "per_page=100&sha=dev&path=src");
    # One encoding, one decoding: the ref is one segment.
    testing.assertEqual($seen[1].path, "/api/v3/repos/me/app/commits/feature/a b");
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/statuses/abc123");
    testing.assertEqual(
        bodyOf($seen[2]),
        '{"context":"ci/build","description":"ok","state":"success","target_url":"https://ci/1"}');
    testing.assertEqual($seen[3].path, "/api/v3/repos/me/app/commits/main/statuses");
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app/commits/main/status");
    testing.assertEqual($seen[6].path, "/api/v3/repos/me/app/commits/main/check-runs");
    try {
        setCommitStatus($c, "me/app", "abc", "warning", "ci", "", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a commit status is one of pending");
    }
}

func testSetSecret() {
    def kp as crypto.Keypair init crypto.keypair("x25519");
    def key as string init '{"key_id":"568250167242549743","key":"' +
        encoding.toText("base64", $kp.public) + '"}';
    def f as Fake init fake([
        ok($key),
        Reply{status: 201, headers: {}, body: ""},
        ok($key),
        answer(204, ""),
        ok('{"key_id":"1","key":"AAAA"}'),
        ok('{"key_id":"1","key":"not base64!"}'),
        ok('{"key_id":"","key":"AAAA"}'),
        # 32 zero bytes, a low-order X25519 point
        ok('{"key_id":"1","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}')
    ]);
    def c as Client init tokenClient($f);
    setSecret($c, "me/app", "DEPLOY_KEY", "s3cr3t é");
    setSecret($c, "me/app", "DEPLOY_KEY", strings.repeat("x", MAX_SECRET_BYTES));
    for (def want in [
        "is 3 bytes, not an X25519 key of 32",
        "is not base64",
        "has no key_id or key",
        "is unusable"
    ]) {
        try {
            setSecret($c, "me/app", "K", "v");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), $want);
        }
    }
    for (def bad in ["", strings.repeat("x", MAX_SECRET_BYTES + 1)]) {
        try {
            setSecret($c, "me/app", "K", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a secret's value is 1 to 49152 bytes");
        }
    }
    try {
        setSecret($c, "me/app", "GITHUB_X", "v");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a secret or variable name");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 8);
    testing.assertEqual($seen[0].method, "GET");
    testing.assertEqual($seen[0].path, "/api/v3/repos/me/app/actions/secrets/public-key");
    testing.assertEqual($seen[1].method, "PUT");
    testing.assertEqual($seen[1].path, "/api/v3/repos/me/app/actions/secrets/DEPLOY_KEY");
    def sent as json.Value init json.decode(convert.stringFromBytes("utf-8", $seen[1].body));
    testing.assertEqual(field($sent, "/key_id"), "568250167242549743");
    def box as bytes init encoding.fromText("base64", field($sent, "/encrypted_value"));
    testing.assertEqual(
        convert.stringFromBytes("utf-8", crypto.unwrap("nacl-sealedbox", $box, $kp.private)),
        "s3cr3t é");
    def big as json.Value init json.decode(convert.stringFromBytes("utf-8", $seen[3].body));
    testing.assertEqual(
        len(encoding.fromText("base64", field($big, "/encrypted_value"))),
        MAX_SECRET_BYTES + 48);
}

func testActions() {
    def run as string init '{"id":77,"name":"release","event":"workflow_dispatch",' +
        '"status":"queued","conclusion":null,"head_branch":"main","head_sha":"abc",' +
        '"html_url":"h","created_at":"t"}';
    def f as Fake init fake([
        ok('{"workflow_run_id":77,"run_url":"u","html_url":"h"}'),
        answer(204, ""),
        ok($run),
        ok('{"total_count":1,"secrets":[{"name":"DEPLOY_KEY","created_at":"t"}]}'),
        answer(204, ""),
        ok('{"total_count":1,"variables":[{"name":"REGION","value":"eu"}]}'),
        answer(404, '{"message":"Not Found"}'),
        Reply{status: 201, headers: {}, body: ""},
        answer(204, ""),
        answer(204, "")
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(
        dispatchWorkflow($c, "me/app", "release.yml", "main", {"level": "minor"}),
        77);
    testing.assertEqual(dispatchWorkflow($c, "me/app", "my flow.yml", "v1", {}), 0);
    def r as WorkflowRun init workflowRun($c, "me/app", 77);
    testing.assertEqual($r.event, "workflow_dispatch");
    testing.assertEqual($r.conclusion, "");
    testing.assertEqual(secrets($c, "me/app"), ["DEPLOY_KEY"]);
    deleteSecret($c, "me/app", "DEPLOY_KEY");
    testing.assertEqual(variables($c, "me/app")["REGION"], "eu");
    setVariable($c, "me/app", "REGION", "us");
    setVariable($c, "me/app", "REGION", "ap");
    deleteVariable($c, "me/app", "REGION");
    def seen as list of Seen init finish($f);
    testing.assertEqual(
        $seen[0].path,
        "/api/v3/repos/me/app/actions/workflows/release.yml/dispatches");
    testing.assertEqual(bodyOf($seen[0]), '{"ref":"main","inputs":{"level":"minor"}}');
    testing.assertEqual(
        $seen[1].path,
        "/api/v3/repos/me/app/actions/workflows/my flow.yml/dispatches");
    testing.assertEqual($seen[2].path, "/api/v3/repos/me/app/actions/runs/77");
    testing.assertEqual($seen[4].method, "DELETE");
    testing.assertEqual($seen[4].path, "/api/v3/repos/me/app/actions/secrets/DEPLOY_KEY");
    # Update answers 404 for a new variable: create it.
    testing.assertEqual($seen[6].method, "PATCH");
    testing.assertEqual($seen[6].path, "/api/v3/repos/me/app/actions/variables/REGION");
    testing.assertEqual($seen[7].method, "POST");
    testing.assertEqual($seen[7].path, "/api/v3/repos/me/app/actions/variables");
    testing.assertEqual(bodyOf($seen[7]), '{"name":"REGION","value":"us"}');
    testing.assertEqual($seen[8].method, "PATCH");
    testing.assertEqual($seen[9].method, "DELETE");
    for (def bad in ["1ABC", "GITHUB_TOKEN", "a-b"]) {
        try {
            deleteSecret($c, "me/app", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a secret or variable name");
        }
    }
    try {
        setVariable($c, "me/app", "X", "");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a variable needs a value");
    }
}

func testGraphql() {
    def f as Fake init fake([
        ok('{"data":{"viewer":{"login":"me"}}}'),
        ok('{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}'),
        answer(401, '{"message":"Bad credentials"}')
    ]);
    def c as Client init tokenClient($f);
    def d as json.Value init graphql($c, 'query { viewer { login } }', json.map());
    testing.assertEqual(json.asString($d, "/viewer/login"), "me");
    try {
        graphql($c, 'query { viewer { login } }', json.map());
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 200);
        testing.assertContains(messageOf($e), "github: POST /graphql: ");
        testing.assertContains(messageOf($e), "API rate limit exceeded");
    }
    try {
        graphql($c, 'query { viewer { login } }', json.map());
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 401);
        testing.assertEqual($e.kind, ERROR_KIND);
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api/graphql");
    testing.assertEqual($seen[0].auth, "Bearer t0k3n");
    testing.assertEqual($seen[0].agent, USER_AGENT);
    testing.assertEqual(bodyOf($seen[0]), '{"query":"query { viewer { login } }","variables":{}}');
    try {
        graphql($c, " ", json.map());
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "github: a GraphQL request needs a query");
    }
}

func testGraphqlTransportFailure() {
    # Nothing listens there any more: a GithubError with status 0.
    def f as Fake init fake([]);
    def c as Client init tokenClient($f);
    finish($f);
    try {
        graphql($c, '{ viewer { login } }', json.map());
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
}

# A local check has status 0; a cap reached in transport stays kind "limit", a
# deadline "timeout", with the request in front of the cause.
func testLocalFailuresAndCaps() {
    try {
        fail("a token holds no spaces");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
    for (def kind in ["limit", "timeout", "closed"]) {
        try {
            failTransport("GET /repos/me/app", Error{kind: $kind, message: "http: cause"});
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, $kind);
            testing.assertEqual($e.message, "github: GET /repos/me/app: http: cause");
        }
    }
    try {
        failTransport("GET /user", Error{kind: "cancelled", message: "task cancelled"});
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "cancelled");
        testing.assertEqual($e.message, "task cancelled");
    }
    try {
        failTransport("GET /user", Error{kind: "http", message: "connection refused"});
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
}

func testReaders() {
    def d as json.Value init json.decode('{"a":"12","b":3.9,"c":true,"e":null,"l":[1,2]}');
    testing.assertEqual(numberAt($d, "/a"), 12);
    testing.assertEqual(numberAt($d, "/b"), 3);
    testing.assertEqual(numberAt($d, "/missing"), 0);
    testing.assertEqual(field($d, "/e"), "");
    testing.assertTrue(flag($d, "/c"));
    testing.assertFalse(flag($d, "/missing"));
    testing.assertEqual(items($d, "/l"), ["/l/0", "/l/1"]);
    testing.assertEqual(items(json.decode("[3]"), ""), ["/0"]);
    testing.assertEqual(objectOf({"a": "1", "b": ""}, {"c": true}), '{"a":"1","c":true}');
}
