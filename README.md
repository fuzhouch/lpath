# Overview

LPath is a command line tool to compute level transition path. It
can be used to estimate time used for a player to finish a game. I use
this tool to compute the play time for Tsetseg's Adventure, my
platformer game with multiple exit in every level.

## Quick build

``lpath`` uses ``zig`` developer branch and ``zigmod`` to build. Before
building please make sure the correct version is used. For
Archlinux users, you may install zig and zigmod from AUR with command
line below. Note that you may also need to install ``zls`` for LSP
support.

```bash
yay -S zig-dev-bin zigmod-bin

## If you need LSP support
git clone https://github.com/zigtools/zls
cd zls
zig build -Doptimize=ReleaseSafe
cp ./zig-out/bin/zls ~/bin/zls
```

After installing correct ``zig`` and ``zigmod`` build, build code from
command below.

```bash
git clone https://github.com/fuzhouch/lpath
cd lpath
zigmod fetch
zig build
```

A command line of lpath looks like below:

```bash
$ ./lpath --profile=tta.toml
```

The ``--profile`` command line argument reads a TOML file, which the
information of each level. The computation logic interpretes TOML file,
understand settings of each level, and print a list of path that player
may go through. Thus, game developer can estimate whether there's any
skills or path that can't be visited.

## How does lpath works

### Requirements

As we explained, lpath tool is to 
In order to make an efficient search, the ``lpath`` tool introduces some
assumptions below:

1. There's one and only one entry level.
2. There's at least one end-level. Game is clear when reaching end-level.
3. Besides starting and end levels, there is zero or more intermediate levels.
4. Intermediate level can have one or more prerequisites.
   Without 100% prerequisites ready, moving to this level is invalid. 
5. A level can be revisited again.
6. A level can attach one or more items. Items are marked as "retrieved"
   when passing through the level.
7. An retrieved item can be referenced as an prerequisite by another level. 
8. One item can be retrieved at most one time.

A typical profile toml can be described as below:

```toml

[1-1]
entry = true

    [1-1.exit]
    next = "1-2"

    [1-1.exit2]
    prerequisite = ["pan"]
    retrieved = ["fireball"]
    next = "2-1"

    [1-1.exit3]
    retrieved = ["glide"]

[1-2]

    [1-2.exit1]
    next = "2-1"

    [1-2.exit2]
    next = "2-1"

    [1-2.exit2]
    retrieved = ["pan"]
    next = "1-2" # Not a true exit.


[2-1]

    [2-1.exit1]
    end = true

    [2-1.exit2]
    prerequisite = ["pan", "glide"]
    next = "1-1"

    [2-1.exit3]
    prerequisite = ["pan", "fireball"]
    next = "2-1" # Not a true exit.

```

## The algorithm

TBD
