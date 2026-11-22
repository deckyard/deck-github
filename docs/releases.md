<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Releases and files

## Releases

```jennifer
def rel as github.Release init github.createRelease(
    $c, "me/app", "1.2.0", "main", "", $notes, false);
github.uploadAsset($c, "me/app", $rel.id, "app-1.2.0.tar.gz", "application/gzip", fs.readBytes("dist/app.tar.gz"));
```

`createRelease` creates the tag at `target` when it does not exist yet; ""
tags the default branch. `latestRelease` is the release GitHub marks as the
latest, by default the newest that is neither a draft nor a pre-release.
`release` finds one by its tag, `releases` lists them, `editRelease` changes
the title or notes, `deleteRelease` removes one and keeps the tag.

`uploadAsset` sends the file to the uploads host with the media type given
(`text/plain; charset=utf-8`, parameters allowed), which GitHub serves it
with; `""` sends `application/octet-stream`. A malformed media type is
refused before anything is sent. A release cannot hold two files of one
name: GitHub answers HTTP 422, and the old one has to go first
(`deleteAsset`).

```jennifer
def latest as github.Release init github.latestRelease($c, "BurntSushi/ripgrep");
for (def a in $latest.assets) {
    if (strings.endsWith($a.name, ".sha256")) {
        io.printf("%s", encoding.decode("utf-8", github.downloadAsset($c, $a, 4096)));
    }
}
```

`downloadAsset` reads the asset through the API, which works for a private
repository too. GitHub answers with a redirect to its storage on another
host (`release-assets.githubusercontent.com`); the deck follows it without
the token, which only ever goes to the client's own server. The file is
held in memory, and one over the limit fails with kind `"limit"`: 64 MiB
with 0, none with a negative limit.

## Branches and tags

```jennifer
github.createBranch($c, "me/app", "release-1.2", "main");
github.createTag($c, "me/app", "1.2.0", "release-1.2", "Release 1.2.0");
github.deleteBranch($c, "me/app", "release-1.2");
```

A tag with a message is annotated (a tag object, then its ref); `""` makes a
lightweight one. `""` as the starting point is the default branch. `tags`
lists names and commits, without annotations. Protected branches refuse to
be deleted.

```jennifer
for (def b in github.branches($c, "me/app")) {
    io.printf("%s %s\n", $b.name, $b.sha);
}
```

## Files

`readFile` reads a file at a branch, tag or commit, up to `maxBytes` (a
larger one fails with kind `"limit"`). As in `downloadAsset`, 0 means
64 MiB and a negative cap none; a cap over `MAX_FILE_BYTES` (GitHub's raw
limit, 100 MB) is refused. A directory is refused; `writeFile` commits a new
version, or the first one:

```jennifer
def v as string init encoding.decode("utf-8", github.readFile($c, "me/app", "VERSION", "main", 4096));
github.writeFile($c, "me/app", "VERSION", encoding.encode("utf-8", "1.2.1"), "bump to 1.2.1", "main");
```

Each `writeFile` is a commit of its own and returns its SHA. It reads the
file first for the blob SHA that replacing it needs. A file in Git LFS reads
as its pointer. `deleteFile` is a commit too; `listDirectory` lists a
directory (at most 1000 entries), `""` the root:

```jennifer
for (def e in github.listDirectory($c, "me/app", "docs", "main")) {
    io.printf("%s %s\n", $e.type, $e.path);
}
github.deleteFile($c, "me/app", "docs/old.md", "drop the old page", "main");
```
