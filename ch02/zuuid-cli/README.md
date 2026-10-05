# zuuid-cli

A command line utility that generates UUIDs using the
[zuuid](https://github.com/mactsouk/zuuid) package.

## Building and running

```bash
zig build                 # build
zig build run -- arg1     # build and run
```

`zig build` downloads the `zuuid` package automatically, based on the
entry found in `build.zig.zon`.

## The zuuid dependency

`build.zig.zon` pins `zuuid` to a specific commit:

```zig
.dependencies = .{
    .zuuidcli = .{
        .url = "git+https://github.com/mactsouk/zuuid?ref=main#<commit>",
        .hash = "zuuid-0.1.0-...",
    },
},
```

- `.url` holds the repository, the branch (`?ref=main`) and the exact
  commit (`#<commit>`).
- `.hash` is the hash of the package contents. Zig verifies it after
  downloading the package.

As the commit is pinned, new commits pushed to `zuuid` are **not** picked
up automatically.

## Updating the dependency

To move to the latest commit of the `main` branch of `zuuid`, run the
next command from this directory:

```bash
zig fetch --save=zuuidcli "git+https://github.com/mactsouk/zuuid#main"
```

- `zig fetch` downloads the package and stores it in the package cache.
- `--save=zuuidcli` writes the result to `build.zig.zon` under the
  `zuuidcli` dependency name, replacing both `.url` and `.hash`. This is
  the name that `build.zig` uses in `b.dependency("zuuidcli", ...)`.
- `#main` is the branch to fetch. Zig resolves it to the current commit
  and stores that commit in `.url`.

After that, rebuild and commit the updated `build.zig.zon`:

```bash
zig build run
```

## Zig versions

The `zuuid` commit must match the Zig version in use. The `main` branch
of this repository pins a `zuuid` commit that builds with Zig 0.17,
whereas the `0.16` branch pins a commit that builds with Zig 0.16.
