# Chapter 01 - Setting Up The Basics

In this chapter, we will set up all the base code required to define a basic rendering loop.
This game loop will have these responsibilities: constantly render new frames; get user inputs; and update the game or application state.
The code presented here is not directly related to Vulkan, but rather the starting point before we dive right in.
You will see something similar in any other application independently of the specific API they use
(this is the reason why we will mainly use large chunks of code here, without explaining step of step every detail).

You can find the complete source code for this chapter [here](../../booksamples/chapter-01).

When posting source code, we wil use `...` to state that there is code above or below the fragment code in a class or in a method.

## Build

The build file (`build.zig`) file is quite standard. It just builds an executable adding the required dependencies and modules.
We will use the following dependencies:

- [SDL3](https://github.com/Gota7/zig-sdl3) Zig bindings. We will use SDL3 to create windows and handel user input.
In order to add the dependency to the `build.zig.zon` file just execute:
`zig fetch --save git+https://github.com/Gota7/zig-sdl3#v0.1.5`
- [TOML](https://github.com/sam701/zig-toml) to be able to parse configuration files.
In order to add the dependency to the `build.zig.zon` file just execute:
`zig fetch --save git+https://github.com/sam701/zig-toml#zig-0.15`
- [Vulkan](https://github.com/Snektron/vulkan-zig) Zig bindings.
In order to add the dependency to the `build.zig.zon` file just execute:
`zig fetch --save git+https://github.com/Snektron/vulkan-zig#zig-0.15-compat`

> [!WARNING]  
> In order for Vulkan to work you will need the [Vulkan SDK](https://vulkan.lunarg.com/sdk/home). Just download the proper package for your
> operative system. Once installed, you will need to set up an environment variable named `VULKAN_SDK` which points to the root folder of the Vulkan SDK.
> The build file assumes that there is a `vk.xml` file in the Vulkan SDK. It will look for it in the following folders:
>
> - `$VULKAN_SDK/share/vulkan/registry`
> - `$VULKAN_SDK/x86_64/share/vulkan/registry`
>
> Make sure the `vk.xml` file is located there or change the path accordingly. It its required to generate the zig Vulkan bindings.

You will need also the Vulkan SDK when enabling validation.

The `build.zig` file is defined like this:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "chapter-01",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // SDL3
    const sdl3Dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .callbacks = false,
        .ext_image = true,
    });
    const sdl3 = sdl3Dep.module("sdl3");
    exe.root_module.addImport("sdl3", sdl3);

    // Vulkan
    const vk_sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch {
        std.debug.panic("Environment variable VULKAN_SDK is not set", .{});
    };
    const primary = std.fs.path.join(b.allocator, &.{ vk_sdk, "share", "vulkan", "registry", "vk.xml" }) catch {
        std.debug.panic("Error constructing vk.xml path", .{});
    };
    const fallback = std.fs.path.join(b.allocator, &.{ vk_sdk, "x86_64", "share", "vulkan", "registry", "vk.xml" }) catch {
        std.debug.panic("Error constructing vk.xml path", .{});
    };
    const vk_xml_abs = blk: {
        if (std.fs.cwd().access(primary, .{})) |_| {
            break :blk primary;
        } else |_| {}

        if (std.fs.cwd().access(fallback, .{})) |_| {
            break :blk fallback;
        } else |_| {}

        std.debug.panic("vk.xml not found in Vulkan SDK", .{});
    };
    const vk_xml: std.Build.LazyPath = .{ .cwd_relative = vk_xml_abs };
    const vulkan_dep = b.dependency("vulkan", .{
        .registry = vk_xml,
    });
    const vulkan = vulkan_dep.module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    // TOML
    const tomlDep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml = tomlDep.module("toml");

    // Com
    const com = b.addModule("com", .{ .root_source_file = b.path("src/eng/com/mod.zig") });
    com.addImport("toml", toml);
    exe.root_module.addImport("com", com);

    // Engine
    const eng = b.addModule("eng", .{ .root_source_file = b.path("src/eng/mod.zig") });
    eng.addImport("com", com);
    eng.addImport("sdl3", sdl3);
    exe.root_module.addImport("eng", eng);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
```

zig build run

## Renderdoc

RENDERDOC: export SDL_VIDEODRIVER=x11