# Overview

LPath is a command line tool to validate stage transition path of a
game. A typical scenario is when a platformer game has a non-linear
stage traversal path, we must validate, that player can really reach
the end-game stage. It is possible that player fail to finish the game
with the following reasons:

1. A stage requires special skills to pass through. However the skills
   can't be retrieved in previous stages. Player are stuck when reaching
   this stage.
2. A stage leads to a circular path, forcing player to endlessly go
   through a path without reaching end of game.

I used ``lpath`` tool to validate my game design of my own game
project, [Tsetesg's Adventure](https://store.steampowered.com/app/2337770).

## Quick start

``lpath`` is developed by (Zig programming language](https://ziglang.org).
For now I use ``zig`` master branch, in order to manage dependencies with
``zigmod`` tool.

For Archlinux users, you may install zig and zigmod from AUR with command
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
$ ./zig-out/bin/lpath --profile=./example.toml
```

The ``--profile`` command line argument reads a TOML file, which the
information of each level. The computation logic interpretes TOML file,
understand settings of each level, and print a list of path that player
may go through. Thus, game developer can estimate whether there's any
skills or path that can't be visited.

## How does lpath work

### Concepts

A game is modeled with the following basic concepts:

1. **Stage**. Stage defines minimal unit that player play through.
2. **Exit**. An exit leading to next stage. So player can move from one
   to another.
3. **Skill**. Skill defines prerequisite when moving to next stage from
   an exit. A skill is always unlocked when passing through a stage. An
   exit can require one or more skills to pass through to next stage.

### Assumptions

With the concepts above, ``lpath`` introduces a model with the following
assumptions:

* A ``profile`` defines one and only one ``game``.
* A ``game`` includes a collection of ``stages``.
* A ``game`` includes one or more ``stages``.
* A ``game`` has one or more ``end-game`` stages.
* A ``game`` has one and only one ``begin-game`` stage.
* A ``stage`` has one or more ``next-stage`` exits. Each exit leads to
  one and only one "next stage".
* A ``stage`` can offer one or more ``skills`` after passing through.
  For example, a BOSS fight stage grants a new skill.
* A ``next-stage`` exit may require one or more ``skills`` to enter.
* Empty string ("") is a speical value because TOML does not allow
  empty array. It's not processed in lpath.

Below is an example:

```toml
[lpath]
skills = ["pan", "glide", "fireball"]

    [[stages]]
    id = "1-1"
    description = "outside-castle"
    begin = true
    next-stage = { "1-2" = [""] }

    [[stages]]
    id = "1-2"
    description = "castle-gate"
    next-stage = { "bossfight1" = [""] }

    [[stages]]
    id = "bossfight1"
    unlock-skills = [ "pan" ]
    next-stage = { "2-1" = [""], "1-1" = [""] }

    [[stages]]
    id = "2-1"
    next-stage = { "2-2" = [""], "2-3" = ["pan"], "2-4" = ["fireball"] }

    [[stages]]
    id = "2-2"
    end = true

    [[stages]]
    id = "2-3"
    next-stage = { "2-5" = ["glide"] }

    [[stages]]
    id = "2-4" # Unreachable due to skill unmatch in 2-1
    end = true

    [[stages]]
    id = "2-5" # Unreachable (2-3 is deadend)
    end = true
```
