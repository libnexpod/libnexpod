# libnexpod
This project hosts the core components of the libnexpod project. This includes the library itself (as the name of the repository implies), the daemon of libnexpod containers and the host-shim (which can technically also be used by other projects).

The library component has the business logic of libnexpod container which currently entails:

- listing out the available images
- the available containers in a namespaced way
- starting and stopping containers
- creating containers
- deleting containers and images
- running commands inside of a container
- tight integration with the host system

The main job daemon of the container keeps the container running until asked to stop, but to also do some house-keeping and making it possible to enhance a container without recreating it.

The job of the host-shim is to forward specific commands (like podman) to the host instead of running it inside of the container.

libnexpod is a wrapper around only podman.

# Why libnexpod when toolbx and distrobox exist and goals
- more features than [toolbx](https://containertoolbx.org/), but with the goal of being just as good (if not better) in reliability
- not as broad of a feature set and supported distros as [distrobox](https://distrobox.it) to allow for better reliability and integration
- library instead of a CLI utility, making it easier to be used by different applications
- usage as not just an integrated container but as a general library for SysAdmin and Developer tools


# Usage
This is a Zig module (C bindings are planned), to use it add it to your `build.zig.zon` file and add the following to your `build.zig`:
```Zig
const libnexpod = b.dependency("libnexpod", .{
    .target = target,
    .optimize = optimize,
});
// root_module is the module you want to add libnexpod to
root_module.addImport("libnexpod", libnexpod.module("libnexpod"));
```

You can generate the standard Zig documentation via `zig build docs`.

For information at how to build the other targets and execute tests, see `zig build --help`.

The host-shim is supposed to be used via a symlink of the actual program you want to call. So if there is a symlink called `podman` to the host-shim which gets called with for example `podman images`, `podman images` will be executed on the host.

# Dependencies
The project has a few library and system dependencies listed here (besides the Linux kernel of course).

| Component | Module Dependency | System Dependency |
| ----- | ----- | ----- |
| library | [zeit](https://github.com/rockorager/zeit) | [podman](https://podman.io) |
| libnexpodd | [zig-clap](https://github.com/Hejsil/zig-clap) | groupadd<br>useradd<br>usermod |
| libnexpod-host-shim | | flatpak-spawn |
