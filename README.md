# @deckyard/github

[![test](https://github.com/deckyard/deck-github/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-github/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-github/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-github)](https://github.com/deckyard/deck-github/releases/latest)

A client for the GitHub REST and GraphQL API, for
[Jennifer](https://jennifer-lang.dev/) programs: github.com or GitHub
Enterprise Server. Repositories with their collaborators and webhooks;
issues, comments, labels and milestones; pull requests, reviews and
merging; releases with their assets; branches, tags and files; commits,
commit statuses, check runs and Actions. `call`, `getAll` and `graphql`
reach everything else. Actions secrets are sealed on the machine before
they are sent.

**[Documentation](https://deckyard.github.io/deck-github/)**

## Install

```sh
jvc add @deckyard/github
```

This vendors the deck to `vendor/<scope>/github/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-github-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/github/" as github;

def c as github.Client init github.client("github.com");
$c = github.withToken($c, os.getEnv("GITHUB_TOKEN"));

for (def i in github.issues($c, "me/app", "open")) {
    io.printf("#%d %s\n", $i.number, $i.title);
}
def rel as github.Release init github.createRelease($c, "me/app", "1.2.0", "", "", "Notes", false);
github.uploadAsset($c, "me/app", $rel.id, "app.tar.gz", fs.readBytes("dist/app.tar.gz"));
```

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (not
`jennifer-tiny`), and the `net` capability.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/github_test.j      # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
