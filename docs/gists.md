<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Gists

A gist is a small set of files with a history of its own. The token needs
the `gist` scope (a classic token) or the "Gists" account permission (a
fine-grained one) to create, change, star or delete one; reading public
gists needs no token.

## Create and change

```jennifer
def g as github.Gist init github.createGist(
    $c, "build notes", false, {"notes.md": "# Notes", "build.sh": "make all"});
io.printf("%s\n", $g.htmlUrl);

$g = github.editGist($c, $g.id, "", {"notes.md": "# Notes\n\nDone."});
$g = github.renameGistFile($c, $g.id, "build.sh", "make.sh");
$g = github.deleteGistFile($c, $g.id, "make.sh");
```

`createGist` takes the files as a map of name to content: at least one, and
none empty (GitHub refuses an empty file). `isPublic` false makes a secret
gist: unlisted, but readable by anyone who has its URL. `editGist` replaces
the content of the files it names and adds new ones; the others stay. A
description of `""` keeps the old one. A name holds no `/`; a bad name, an
empty content or an edit with nothing in it is refused before anything is
sent. GitHub keeps at least one file in a gist and refuses to remove the
last (HTTP 422).

## Read

```jennifer
for (def g in github.userGists($c, "octocat")) {
    io.printf("%s %s\n", $g.id, $g.description);
}
def g as github.Gist init github.gist($c, "aa5a315d61ae9438b18d");
for (def file in $g.files) {
    def text as string init $file.content;
    if ($file.isTruncated) {
        $text = encoding.decode("utf-8", github.gistContent($c, $file, 0));
    }
    io.printf("== %s (%d bytes)\n%s\n", $file.name, $file.size, $text);
}
```

A listing (`gists`, `userGists`, `starredGists`) gives each file's name,
type and size, not its content; `gist` reads one gist with the content.
GitHub cuts a file over a megabyte short there and marks it `isTruncated`;
`gistContent` then reads it whole from its `rawUrl`. github.com serves that
from `gist.githubusercontent.com`, another host: it gets no token (a secret
gist's raw URL needs none) and must be https. On an Enterprise Server the
raw URL is on the server itself and the token goes along. The file is held
in memory, 64 MiB at most unless `maxBytes` says otherwise (negative for no
limit); a larger one fails with kind `"limit"`. A gist of more than 300
files lists only the first 300, marked `isTruncated` on the `Gist`.

## Revisions, forks and stars

```jennifer
for (def r in github.gistRevisions($c, $id)) {
    io.printf("%s %s +%d -%d\n", $r.version[..7], $r.committed, $r.additions, $r.deletions);
}
def old as github.Gist init github.gistRevision($c, $id, $revs[1].version);
github.starGist($c, $id);
io.printf("starred: %v\n", github.isGistStarred($c, $id));
def mine as github.Gist init github.forkGist($c, $id);
```

`gistRevision` takes a revision's 40-hex SHA from `gistRevisions`.
`forkGist` copies someone else's gist into the token's account; GitHub
refuses to fork one's own (HTTP 422). `isGistStarred` reads GitHub's 404 as
"not starred"; any other failure throws.
