# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * Download an asset of a repository's latest release and check it against
 * the `<asset>.sha256` file published next to it.
 *
 *   jennifer run examples/checksum.j BurntSushi/ripgrep \
 *       ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz
 *
 * The asset is held in memory, up to 256 MiB, and not written anywhere.
 * Set GITHUB_TOKEN for a private repository.
 */
use encoding;
use hash;
use io;
use os;
use strings;

import "../src/github.j" as github;

if (len(os.ARGS) != 3) {
    throw Error{kind: "usage", message: "usage: checksum.j <owner/name> <asset>"};
}
def repo as string init os.ARGS[1];
def name as string init os.ARGS[2];

def c as github.Client init github.client("github.com");
if (os.hasEnv("GITHUB_TOKEN")) {
    $c = github.withToken($c, os.getEnv("GITHUB_TOKEN"));
}

def rel as github.Release init github.latestRelease($c, $repo);
def file as github.Asset;
def sum as github.Asset;
for (def a in $rel.assets) {
    if ($a.name == $name) {
        $file = $a;
    } elseif ($a.name == $name + ".sha256") {
        $sum = $a;
    }
}
if ($file.name == "" or $sum.name == "") {
    throw Error{
        kind: "usage",
        message: "release " + $rel.tag + " has no " + $name + " with a .sha256 beside it"
    };
}

def data as bytes init github.downloadAsset($c, $file, 268435456);
def want as string init strings.split(
    strings.trim(encoding.decode("utf-8", github.downloadAsset($c, $sum, 4096))),
    " ")[0];
def got as string init encoding.toText("hex", hash.compute("sha256", $data));
io.printf("%s %s: %d bytes, sha256 %s\n", $rel.tag, $name, len($data), $got);
if (strings.lower($want) != $got) {
    throw Error{kind: "checksum", message: "expected sha256 " + $want};
}
io.printf("checksum ok\n");
