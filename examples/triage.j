# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * Summarize a repository: its latest release and the open issues without
 * a label.
 *
 *   jennifer run examples/triage.j BurntSushi/ripgrep
 *
 * Reads public data anonymously from github.com (60 requests an hour per
 * address); set GITHUB_TOKEN for more, or for a private repository, and
 * GITHUB_URL for an Enterprise Server.
 */
use io;
use os;

import "../src/github.j" as github;

if (len(os.ARGS) != 2) {
    throw Error{kind: "usage", message: "usage: triage.j <owner/name>"};
}
def repo as string init os.ARGS[1];

def url as string init "github.com";
if (os.hasEnv("GITHUB_URL")) {
    $url = os.getEnv("GITHUB_URL");
}
def c as github.Client init github.withRetries(github.client($url), 2);
if (os.hasEnv("GITHUB_TOKEN")) {
    $c = github.withToken($c, os.getEnv("GITHUB_TOKEN"));
}

def r as github.Repository init github.repository($c, $repo);
io.printf(
    "%s: %d open issues and pull requests, default branch %s\n",
    $r.fullName,
    $r.openIssues,
    $r.defaultBranch);

# A repository without releases answers 404 here.
try {
    def rel as github.Release init github.latestRelease($c, $repo);
    io.printf("latest release %s, %d assets\n", $rel.tag, len($rel.assets));
} catch (e) {
    if ($e.kind != github.ERROR_KIND or $e.status != 404) {
        throw $e;
    }
    io.printf("no release yet\n");
}

for (def i in github.issues($c, $repo, "open")) {
    if (len($i.labels) == 0) {
        io.printf("  unlabelled #%d %s\n", $i.number, $i.title);
    }
}
