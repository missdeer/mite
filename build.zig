pub fn build(b: *std.Build) void {
    const target = target: {
        var result = b.standardTargetOptions(.{});
        if (result.result.os.tag != .windows) {
            std.debug.panic(
                "Mostty is Windows-only; use -Dtarget=x86_64-windows-msvc or build on Windows without -Dtarget",
                .{},
            );
        }
        // On Windows, default to MSVC ABI. The ghostty-vt module's C++ source
        // files (src/simd/*.cpp) are compiled with MSVC ABI because ghostty's
        // own build.zig forces it, so the exe ABI must match or clang's
        // intrinsics headers break under MSVC SDK include paths. Mirror the
        // override from ghostty's src/build/Config.zig.
        if (result.result.os.tag == .windows and result.query.abi == null) {
            var query = result.query;
            query.abi = .msvc;
            result = b.resolveTargetQuery(query);
        }
        // Mostty's Windows build only supports MSVC ABI today: the WinMain
        // shim, libcmt entry point, and ghostty-vt's C++ ABI all assume it.
        // Fail fast on explicit Windows-GNU to avoid a confusing link error.
        if (result.result.os.tag == .windows and result.result.abi != .msvc) {
            std.debug.panic(
                "Mostty's Windows build requires MSVC ABI; use -Dtarget=x86_64-windows-msvc or omit -Dtarget",
                .{},
            );
        }
        break :target result;
    };
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{
        .target = target,
        .optimize = optimize,
    };
    const vt = b.dependency("ghostty", dep_opts).module("ghostty-vt");
    const z2d = b.dependency("z2d", dep_opts).module("z2d");
    const shader_assets = buildShaders(b);

    const main = b.path("src/mosttywindows.zig");
    const exe = b.addExecutable(.{
        .name = "Mostty",
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("src/win32/mostty.manifest"),
    });
    addImports(b, exe.root_module, vt, z2d, shader_assets);
    addShaderValidationDependencies(&exe.step, shader_assets);

    exe.addWin32ResourceFile(.{
        .file = b.path("src/win32/mostty.rc"),
    });
    exe.subsystem = .Windows;

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // Ship the bundled themes next to the exe so a config's `theme = <name>`
    // resolves via the <exeDir>/themes/<name> lookup. exe installs to bin/, so
    // exeDir is zig-out/bin and the themes must land in zig-out/bin/themes.
    const install_themes = b.addInstallDirectory(.{
        .source_dir = b.path("themes"),
        .install_dir = .bin,
        .install_subdir = "themes",
    });
    b.getInstallStep().dependOn(&install_themes.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
        }),
    });
    addImports(b, tests.root_module, vt, z2d, shader_assets);
    addShaderValidationDependencies(&tests.step, shader_assets);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn addImports(
    b: *std.Build,
    mod: *std.Build.Module,
    vt: *std.Build.Module,
    z2d: *std.Build.Module,
    shader_assets: ShaderAssets,
) void {
    mod.addImport("vt", vt);
    mod.addImport("z2d", z2d);
    mod.addAnonymousImport("terminal_vertex.dxbc", .{ .root_source_file = shader_assets.vertex.dxbc });
    mod.addAnonymousImport("terminal_vertex.spv", .{ .root_source_file = shader_assets.vertex.spirv });
    mod.addAnonymousImport("terminal_pixel.dxbc", .{ .root_source_file = shader_assets.pixel.dxbc });
    mod.addAnonymousImport("terminal_pixel.spv", .{ .root_source_file = shader_assets.pixel.spirv });
    mod.addAnonymousImport("terminal_image_pixel.dxbc", .{ .root_source_file = shader_assets.image_pixel.dxbc });
    mod.addAnonymousImport("terminal_image_pixel.spv", .{ .root_source_file = shader_assets.image_pixel.spirv });
    if (b.lazyDependency("win32", .{})) |win32_dep| {
        mod.addImport("win32", win32_dep.module("win32"));
        mod.addIncludePath(b.path("src/win32"));
    }
}

const ShaderPair = struct {
    dxbc: std.Build.LazyPath,
    spirv: std.Build.LazyPath,
    validation: *std.Build.Step,
};

const ShaderAssets = struct {
    vertex: ShaderPair,
    pixel: ShaderPair,
    image_pixel: ShaderPair,
};

fn buildShaders(b: *std.Build) ShaderAssets {
    const fxc = findSdkTool(b, .{
        .option_name = "fxc-path",
        .option_description = "Path to the Windows SDK fxc.exe used for D3D11 shader assets",
        .env_name = "WindowsSdkVerBinPath",
        .env_suffix = "x64/fxc.exe",
        .search_root = "C:/Program Files (x86)/Windows Kits/10/bin",
        .search_suffix = "x64/fxc.exe",
        .install_hint = "install the Windows SDK or pass -Dfxc-path=<path>",
    });
    const dxc = findSdkTool(b, .{
        .option_name = "dxc-path",
        .option_description = "Path to a SPIR-V-enabled dxc.exe",
        .env_name = "VULKAN_SDK",
        .env_suffix = "Bin/dxc.exe",
        .search_root = "C:/VulkanSDK",
        .search_suffix = "Bin/dxc.exe",
        .install_hint = "install the LunarG Vulkan SDK or pass -Ddxc-path=<path>",
    });
    const dxc_dir = std.fs.path.dirname(dxc) orelse ".";
    const spirv_validator = requireTool(
        b,
        b.pathJoin(&.{ dxc_dir, "spirv-val.exe" }),
        "use a LunarG Vulkan SDK DXC installation that includes spirv-val.exe",
    );
    const source = b.path("src/win32/terminal.hlsl");

    return .{
        .vertex = compileShaderPair(b, fxc, dxc, spirv_validator, source, "VertexMain", "vs_5_0", "vs_6_0", "terminal_vertex"),
        .pixel = compileShaderPair(b, fxc, dxc, spirv_validator, source, "PixelMain", "ps_5_0", "ps_6_0", "terminal_pixel"),
        .image_pixel = compileShaderPair(b, fxc, dxc, spirv_validator, source, "ImagePixelMain", "ps_5_0", "ps_6_0", "terminal_image_pixel"),
    };
}

fn compileShaderPair(
    b: *std.Build,
    fxc: []const u8,
    dxc: []const u8,
    spirv_validator: []const u8,
    source: std.Build.LazyPath,
    entry: []const u8,
    dxbc_profile: []const u8,
    spirv_profile: []const u8,
    basename: []const u8,
) ShaderPair {
    const dxbc_command = b.addSystemCommand(&.{ fxc, "/nologo", "/E", entry, "/T", dxbc_profile, "/Fo" });
    const dxbc = dxbc_command.addOutputFileArg(b.fmt("{s}.dxbc", .{basename}));
    dxbc_command.addFileArg(source);

    const spirv_command = b.addSystemCommand(&.{
        dxc,
        "-spirv",
        "-fspv-target-env=vulkan1.1",
        "-DSPIRV=1",
        "-E",
        entry,
        "-T",
        spirv_profile,
        "-Fo",
    });
    const spirv = spirv_command.addOutputFileArg(b.fmt("{s}.spv", .{basename}));
    spirv_command.addFileArg(source);

    const validation_command = b.addSystemCommand(&.{ spirv_validator, "--target-env", "vulkan1.1" });
    validation_command.addFileArg(spirv);

    return .{ .dxbc = dxbc, .spirv = spirv, .validation = &validation_command.step };
}

fn addShaderValidationDependencies(step: *std.Build.Step, assets: ShaderAssets) void {
    step.dependOn(assets.vertex.validation);
    step.dependOn(assets.pixel.validation);
    step.dependOn(assets.image_pixel.validation);
}

const SdkToolOptions = struct {
    option_name: []const u8,
    option_description: []const u8,
    env_name: []const u8,
    env_suffix: []const u8,
    search_root: []const u8,
    search_suffix: []const u8,
    install_hint: []const u8,
};

fn findSdkTool(b: *std.Build, options: SdkToolOptions) []const u8 {
    if (b.option([]const u8, options.option_name, options.option_description)) |path| {
        return requireTool(b, path, options.install_hint);
    }
    if (b.graph.env_map.get(options.env_name)) |root| {
        const path = b.pathJoin(&.{ root, options.env_suffix });
        if (toolExists(path)) return path;
    }

    var root = std.fs.openDirAbsolute(options.search_root, .{ .iterate = true }) catch {
        std.debug.panic("shader compiler not found: {s}", .{options.install_hint});
    };
    defer root.close();

    var newest_version: ?[]const u8 = null;
    var newest_path: ?[]const u8 = null;
    var iterator = root.iterate();
    while (iterator.next() catch @panic("failed to enumerate SDK versions")) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = b.pathJoin(&.{ options.search_root, entry.name, options.search_suffix });
        if (!toolExists(candidate)) continue;
        if (newest_version == null or versionLessThan(newest_version.?, entry.name)) {
            newest_version = b.dupe(entry.name);
            newest_path = candidate;
        }
    }
    return newest_path orelse std.debug.panic("shader compiler not found: {s}", .{options.install_hint});
}

fn requireTool(b: *std.Build, path: []const u8, install_hint: []const u8) []const u8 {
    if (!toolExists(path)) std.debug.panic("shader compiler not found at '{s}': {s}", .{ path, install_hint });
    return b.dupe(path);
}

fn toolExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}

fn versionLessThan(lhs: []const u8, rhs: []const u8) bool {
    var lhs_parts = std.mem.tokenizeScalar(u8, lhs, '.');
    var rhs_parts = std.mem.tokenizeScalar(u8, rhs, '.');
    while (true) {
        const lhs_part = lhs_parts.next();
        const rhs_part = rhs_parts.next();
        if (lhs_part == null or rhs_part == null) return lhs_part == null and rhs_part != null;
        const lhs_number = std.fmt.parseUnsigned(u32, lhs_part.?, 10) catch return std.mem.lessThan(u8, lhs, rhs);
        const rhs_number = std.fmt.parseUnsigned(u32, rhs_part.?, 10) catch return std.mem.lessThan(u8, lhs, rhs);
        if (lhs_number != rhs_number) return lhs_number < rhs_number;
    }
}

const std = @import("std");
