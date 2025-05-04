const std = @import("std");
const Builder = std.Build;
const Module = std.Build.Module;
const LibExeObjStep = std.Build.Step.Compile; // Alias for clarity
const RunStep = std.Build.Step.Run;
const fs = std.fs;
const LazyPath = std.Build.LazyPath; // Import LazyPath for convenience

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_name = b.option(
        []const u8,
        "exe_name",
        "Name of the executable",
    ) orelse "ziq";

    // --- Configuration ---
    // !! IMPORTANT: Adjust these paths !!
    const unibilium_source_path = "../unibilium";       // Relative path example
    const termkey_source_path = "../libtermkey-0.23"; // Relative path example
    const tickit_source_path = "../libtickit-0.4.5";    // Relative path example (UPDATE THIS)

    const unibilium_root_path_lazy: LazyPath = b.path(unibilium_source_path);
    const termkey_root_path_lazy: LazyPath = b.path(termkey_source_path);
    const tickit_root_path_lazy: LazyPath = b.path(tickit_source_path);

    // --- Build Unibilium (Dependency) ---

    const terminfo_dirs_define = blk: {
        var dirs: []const u8 = "";
        // Keep only relevant OSes for brevity in example
        switch (target.result.os.tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .solaris, .illumos => {
                dirs = "/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo";
            },
            else => {},
        }
        break :blk b.fmt("-DTERMINFO_DIRS=\"{s}\"", .{dirs});
    };

    const unibilium_module = b.createModule(.{
        .root_source_file = null, // C library
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unibilium_module.addCSourceFiles(.{
        .files = &.{ "unibilium.c", "uninames.c", "uniutil.c" },
        .root = unibilium_root_path_lazy, // Use LazyPath here
        .flags = &.{ "-Wall", "-std=c99", terminfo_dirs_define },
    });
    // Use the LazyPath directly for include paths
    unibilium_module.addIncludePath(unibilium_root_path_lazy);

    const unibilium_lib = b.addLibrary(.{
        .name = "unibilium",
        .root_module = unibilium_module,
        .linkage = .static, // Static library
    });
    // Use LazyPath pointing *to the file* for installing headers
    unibilium_lib.installHeader(unibilium_root_path_lazy.path(b, "unibilium.h"), "unibilium.h");

    // --- Build Libtermkey (Depends on Unibilium) ---

    const termkey_module = b.createModule(.{
        .root_source_file = null, // C library
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add libtermkey's C source files
    termkey_module.addCSourceFiles(.{
        .files = &.{
            "termkey.c",
            "driver-csi.c",
            "driver-ti.c",
        },
        .root = termkey_root_path_lazy, // Use LazyPath here
        // Define HAVE_UNIBILIUM because we are building unibilium from source
        .flags = &.{ "-Wall", "-std=c99", "-DHAVE_UNIBILIUM" },
    });

    // Add include path for termkey.h / termkey-internal.h
    termkey_module.addIncludePath(termkey_root_path_lazy);
    // Add include path for unibilium.h (needed by termkey.c when HAVE_UNIBILIUM is defined)
    termkey_module.addIncludePath(unibilium_root_path_lazy);

    // Create the libtermkey static library
    const termkey_lib = b.addLibrary(.{
        .name = "termkey",
        .root_module = termkey_module,
        .linkage = .static, // Static library
    });

    // Link unibilium INTO libtermkey
    termkey_lib.linkLibrary(unibilium_lib);
    termkey_lib.installHeader(termkey_root_path_lazy.path(b, "termkey.h"), "termkey.h");


    // --- Build Libtickit (Depends on Libtermkey [and Unibilium]) ---

    // ** Generate .inc files using Perl scripts **
    // NOTE: This introduces a build-time dependency on 'perl'.
    // We'll generate these into the build cache to avoid modifying the source dir.

    // Note: b.pathJoin returns []u8, which is fine for system commands
    const tickit_generated_dir_path = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "tickit-gen" });
    // Use .cwd_relative because tickit_generated_dir_path is absolute or CWD-relative.
    const tickit_generated_dir_lazy: LazyPath = .{ .cwd_relative = tickit_generated_dir_path };

    // Ensure the generated directory exists
    const mkdir_gen_step = b.addSystemCommand(&.{"mkdir", "-p", tickit_generated_dir_path});

    // Generate xterm-palette.inc
    // Use b.pathJoin for system command arguments which expect []const u8
    const xterm_script_path = b.pathJoin(&.{tickit_source_path, "src", "xterm-palette.inc.PL"});
    const xterm_output_path = b.pathJoin(&.{tickit_generated_dir_path, "xterm-palette.inc"});
    // Using sh -c for redirection '>' as addSystemCommand doesn't handle it directly.
    // This adds a dependency on a basic shell like sh/bash.
    const xterm_cmd_str = b.fmt("perl {s} > {s}", .{xterm_script_path, xterm_output_path});
    const gen_xterm_palette_step = b.addSystemCommand(&.{ "sh", "-c", xterm_cmd_str });
    gen_xterm_palette_step.step.dependOn(&mkdir_gen_step.step);

    // Generate linechars.inc
    const linechars_script_path = b.pathJoin(&.{tickit_source_path, "src", "linechars.inc.PL"});
    const linechars_output_path = b.pathJoin(&.{tickit_generated_dir_path, "linechars.inc"});
    const linechars_cmd_str = b.fmt("perl {s} > {s}", .{linechars_script_path, linechars_output_path});
    const gen_linechars_step = b.addSystemCommand(&.{ "sh", "-c", linechars_cmd_str });
    gen_linechars_step.step.dependOn(&mkdir_gen_step.step);

    // Generate fullwidth.inc
    const fullwidth_script_path = b.pathJoin(&.{tickit_source_path, "src", "fullwidth.inc.PL"});
    const fullwidth_output_path = b.pathJoin(&.{tickit_generated_dir_path, "fullwidth.inc"});
    const fullwidth_cmd_str = b.fmt("perl {s} > {s}", .{fullwidth_script_path, fullwidth_output_path});
    const gen_fullwidth_step = b.addSystemCommand(&.{ "sh", "-c", fullwidth_cmd_str });
    gen_fullwidth_step.step.dependOn(&mkdir_gen_step.step);


    // Create the libtickit module
    const tickit_module = b.createModule(.{
        .root_source_file = null, // C library
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add libtickit's C source files - ** Using user-provided list for v0.4.5 **
    tickit_module.addCSourceFiles(.{
        .files = &.{
            "./src/bindings.c",
            "./src/debug.c",          // ADDED
            "./src/evloop-default.c", // ADDED
            "./src/mockterm.c",       // ADDED
            "./src/pen.c",
            "./src/rect.c",
            "./src/rectset.c",        // ADDED
            "./src/renderbuffer.c",   // Depends on linechars.inc
            "./src/string.c",
            "./src/term.c",           // Depends on xterm-palette.inc
            "./src/termdriver-ti.c",  // ADDED
            "./src/termdriver-xterm.c",// ADDED
            "./src/tickit.c",
            "./src/utf8.c",           // Depends on fullwidth.inc
            "./src/window.c",
        },
        .root = tickit_root_path_lazy, // Use LazyPath here
        // Add flags based on Makefile analysis
        .flags = &.{
            "-Wall",
            "-std=c99",
            "-DHAVE_UNIBILIUM", // We are providing unibilium
            // We add include paths manually, no need for pkg-config flags here
        },
    });

    // --- Corrected Include Paths using LazyPath.path ---
    // Add include paths for libtickit
    tickit_module.addIncludePath(tickit_root_path_lazy.path(b, "include")); // Public headers
    tickit_module.addIncludePath(tickit_root_path_lazy.path(b, "src"));     // Internal headers
    tickit_module.addIncludePath(tickit_generated_dir_lazy);                // Generated .inc files (using the corrected LazyPath)

    // Add include paths for dependencies (these are already LazyPath)
    tickit_module.addIncludePath(termkey_root_path_lazy); // For termkey.h
    tickit_module.addIncludePath(unibilium_root_path_lazy); // For unibilium.h (needed due to HAVE_UNIBILIUM)
    // --- End Correction ---

    // Create the libtickit static library
    const tickit_lib = b.addLibrary(.{
        .name = "tickit",
        .root_module = tickit_module,
        .linkage = .static, // Static library
    });

    // ** Important: Ensure libtickit compilation depends on the generated files **
    tickit_lib.step.dependOn(&gen_xterm_palette_step.step);
    tickit_lib.step.dependOn(&gen_linechars_step.step);
    tickit_lib.step.dependOn(&gen_fullwidth_step.step);

    // Link termkey (which includes unibilium) INTO libtickit
    tickit_lib.linkLibrary(termkey_lib);

    // Install tickit headers using LazyPath
    tickit_lib.installHeadersDirectory(
        tickit_root_path_lazy.path(b, "include"),
        "tickit", // Install into include/tickit/
         .{},
    );


    // --- Build Your Executable ---

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add include paths for @cImport in your Zig code
    // (already LazyPath)
    exe_module.addIncludePath(unibilium_root_path_lazy);
    exe_module.addIncludePath(termkey_root_path_lazy);
    // Use LazyPath.path()
    exe_module.addIncludePath(tickit_root_path_lazy.path(b, "include"));

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_module,
    });

    // Link the final library (tickit, which already contains termkey & unibilium)
    exe.linkLibrary(tickit_lib);
    // Note: Linking termkey_lib or unibilium_lib again explicitly is redundant

    b.installArtifact(exe);

    // --- Run Step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| { run_cmd.addArgs(args); }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Test Step ---
    const test_filter = b.option([]const u8, "test-filter", "Filter for tests to run");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), // Assuming tests are here
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add include paths for tests if they use C headers
    // (already LazyPath)
    test_module.addIncludePath(unibilium_root_path_lazy);
    test_module.addIncludePath(termkey_root_path_lazy);
    // Use LazyPath.path()
    test_module.addIncludePath(tickit_root_path_lazy.path(b, "include"));

    const exe_unit_tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });

    // Link libtickit (and transitively termkey/unibilium) to tests
    exe_unit_tests.linkLibrary(tickit_lib);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
