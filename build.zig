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
    const vulkan_include = findVulkanInclude(b);

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
    addImports(b, exe.root_module, vt, z2d, shader_assets, vulkan_include);
    exe.root_module.linkSystemLibrary("opengl32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
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
    addImports(b, tests.root_module, vt, z2d, shader_assets, vulkan_include);
    tests.root_module.linkSystemLibrary("opengl32", .{});
    tests.root_module.linkSystemLibrary("gdi32", .{});
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
    vulkan_include: []const u8,
) void {
    mod.addImport("vt", vt);
    mod.addImport("z2d", z2d);
    mod.addAnonymousImport("terminal_vertex.dxbc", .{ .root_source_file = shader_assets.vertex.dxbc });
    mod.addAnonymousImport("terminal_vertex.dxil", .{ .root_source_file = shader_assets.vertex.dxil });
    mod.addAnonymousImport("terminal_vertex.spv", .{ .root_source_file = shader_assets.vertex.spirv });
    mod.addAnonymousImport("terminal_vertex.vulkan.spv", .{ .root_source_file = shader_assets.vertex.vulkan_spirv });
    mod.addAnonymousImport("terminal_pixel.dxbc", .{ .root_source_file = shader_assets.pixel.dxbc });
    mod.addAnonymousImport("terminal_pixel.dxil", .{ .root_source_file = shader_assets.pixel.dxil });
    mod.addAnonymousImport("terminal_pixel.spv", .{ .root_source_file = shader_assets.pixel.spirv });
    mod.addAnonymousImport("terminal_pixel.vulkan.spv", .{ .root_source_file = shader_assets.pixel.vulkan_spirv });
    mod.addAnonymousImport("terminal_image_pixel.dxbc", .{ .root_source_file = shader_assets.image_pixel.dxbc });
    mod.addAnonymousImport("terminal_image_pixel.dxil", .{ .root_source_file = shader_assets.image_pixel.dxil });
    mod.addAnonymousImport("terminal_image_pixel.spv", .{ .root_source_file = shader_assets.image_pixel.spirv });
    mod.addAnonymousImport("terminal_image_pixel.vulkan.spv", .{ .root_source_file = shader_assets.image_pixel.vulkan_spirv });
    mod.addAnonymousImport("terminal_present_pixel.dxbc", .{ .root_source_file = shader_assets.present_pixel });
    if (b.lazyDependency("win32", .{})) |win32_dep| {
        mod.addImport("win32", win32_dep.module("win32"));
        mod.addIncludePath(b.path("src/win32"));
        mod.addIncludePath(.{ .cwd_relative = vulkan_include });
    }
}

const ShaderTargets = struct {
    dxbc: std.Build.LazyPath,
    dxil: std.Build.LazyPath,
    spirv: std.Build.LazyPath,
    vulkan_spirv: std.Build.LazyPath,
    validation: *std.Build.Step,
};

const ShaderAssets = struct {
    vertex: ShaderTargets,
    pixel: ShaderTargets,
    image_pixel: ShaderTargets,
    present_pixel: std.Build.LazyPath,
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
    const spirv_cross = findSdkTool(b, .{
        .option_name = "spirv-cross-path",
        .option_description = "Path to spirv-cross.exe used to normalize DXC output for OpenGL",
        .env_name = "VULKAN_SDK",
        .env_suffix = "Bin/spirv-cross.exe",
        .search_root = "C:/VulkanSDK",
        .search_suffix = "Bin/spirv-cross.exe",
        .install_hint = "install the LunarG Vulkan SDK or pass -Dspirv-cross-path=<path>",
    });
    const glslang_validator = findSdkTool(b, .{
        .option_name = "glslang-validator-path",
        .option_description = "Path to glslangValidator.exe used to emit OpenGL SPIR-V",
        .env_name = "VULKAN_SDK",
        .env_suffix = "Bin/glslangValidator.exe",
        .search_root = "C:/VulkanSDK",
        .search_suffix = "Bin/glslangValidator.exe",
        .install_hint = "install the LunarG Vulkan SDK or pass -Dglslang-validator-path=<path>",
    });
    const spirv_validator = findSdkTool(b, .{
        .option_name = "spirv-val-path",
        .option_description = "Path to spirv-val.exe used to validate Vulkan and OpenGL shader assets",
        .env_name = "VULKAN_SDK",
        .env_suffix = "Bin/spirv-val.exe",
        .search_root = "C:/VulkanSDK",
        .search_suffix = "Bin/spirv-val.exe",
        .install_hint = "install the LunarG Vulkan SDK or pass -Dspirv-val-path=<path>",
    });
    // DXIL needs a *different* DXC than SPIR-V: signing requires dxil.dll next
    // to the compiler, which the Vulkan SDK distribution omits. D3D12 rejects
    // unsigned DXIL outside developer mode, so `sibling` makes signing capability
    // part of tool discovery — an SDK with dxc.exe but no dxil.dll must be
    // skipped over, not selected and then rejected.
    const dxil_dxc = findSdkTool(b, .{
        .option_name = "dxil-dxc-path",
        .option_description = "Path to a signing-capable dxc.exe (dxil.dll must sit alongside it) used for D3D12 shader assets",
        .env_name = "WindowsSdkVerBinPath",
        .env_suffix = "x64/dxc.exe",
        .search_root = "C:/Program Files (x86)/Windows Kits/10/bin",
        .search_suffix = "x64/dxc.exe",
        .sibling = "dxil.dll",
        .install_hint = "D3D12 rejects unsigned DXIL; install a Windows SDK whose x64 dxc.exe ships dxil.dll alongside it, or pass -Ddxil-dxc-path=<path>",
    });
    const source = b.path("src/win32/terminal.hlsl");

    const tools = ShaderTools{
        .fxc = fxc,
        .dxc = dxc,
        .dxil_dxc = dxil_dxc,
        .spirv_cross = spirv_cross,
        .glslang_validator = glslang_validator,
        .spirv_validator = spirv_validator,
    };

    const present_pixel_command = b.addSystemCommand(&.{ fxc, "/nologo", "/E", "PresentPixelMain", "/T", "ps_5_0", "/Fo" });
    const present_pixel = present_pixel_command.addOutputFileArg("terminal_present_pixel.dxbc");
    present_pixel_command.addFileArg(source);

    return .{
        .vertex = compileShaderTargets(b, tools, source, "VertexMain", "vs_5_0", "vs_6_0", "vert", "terminal_vertex"),
        .pixel = compileShaderTargets(b, tools, source, "PixelMain", "ps_5_0", "ps_6_0", "frag", "terminal_pixel"),
        .image_pixel = compileShaderTargets(b, tools, source, "ImagePixelMain", "ps_5_0", "ps_6_0", "frag", "terminal_image_pixel"),
        .present_pixel = present_pixel,
    };
}

const ShaderTools = struct {
    fxc: []const u8,
    dxc: []const u8,
    dxil_dxc: []const u8,
    spirv_cross: []const u8,
    glslang_validator: []const u8,
    spirv_validator: []const u8,
};

fn compileShaderTargets(
    b: *std.Build,
    tools: ShaderTools,
    source: std.Build.LazyPath,
    entry: []const u8,
    dxbc_profile: []const u8,
    sm6_profile: []const u8,
    glsl_stage: []const u8,
    basename: []const u8,
) ShaderTargets {
    const dxbc_command = b.addSystemCommand(&.{ tools.fxc, "/nologo", "/E", entry, "/T", dxbc_profile, "/Fo" });
    const dxbc = dxbc_command.addOutputFileArg(b.fmt("{s}.dxbc", .{basename}));
    dxbc_command.addFileArg(source);

    const dxil_command = b.addSystemCommand(&.{ tools.dxil_dxc, "-E", entry, "-T", sm6_profile, "-Fo" });
    const dxil = dxil_command.addOutputFileArg(b.fmt("{s}.dxil", .{basename}));
    dxil_command.addFileArg(source);

    const spirv_command = b.addSystemCommand(&.{
        tools.dxc,
        "-spirv",
        "-fspv-target-env=vulkan1.0",
        "-DSPIRV=1",
        "-E",
        entry,
        "-T",
        sm6_profile,
        "-Fo",
    });
    const spirv_raw = spirv_command.addOutputFileArg(b.fmt("{s}.raw.spv", .{basename}));
    spirv_command.addFileArg(source);

    const vulkan_validation_command = b.addSystemCommand(&.{ tools.spirv_validator, "--target-env", "vulkan1.0" });
    vulkan_validation_command.addFileArg(spirv_raw);

    const cross_command = b.addSystemCommand(&.{
        tools.spirv_cross,
        "--version",
        "460",
        "--combined-samplers-inherit-bindings",
        "--output",
    });
    const glsl = cross_command.addOutputFileArg(b.fmt("{s}.glsl", .{basename}));
    cross_command.addFileArg(spirv_raw);

    const glslang_command = b.addSystemCommand(&.{
        tools.glslang_validator,
        "-G",
        "--target-env",
        "opengl",
        "-S",
        glsl_stage,
        "--source-entrypoint",
        "main",
        "-e",
        entry,
        "-o",
    });
    const spirv = glslang_command.addOutputFileArg(b.fmt("{s}.spv", .{basename}));
    glslang_command.addFileArg(glsl);

    const opengl_validation_command = b.addSystemCommand(&.{ tools.spirv_validator, "--target-env", "opengl4.5" });
    opengl_validation_command.addFileArg(spirv);
    opengl_validation_command.step.dependOn(&vulkan_validation_command.step);

    return .{
        .dxbc = dxbc,
        .dxil = dxil,
        .spirv = spirv,
        .vulkan_spirv = spirv_raw,
        .validation = &opengl_validation_command.step,
    };
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
    /// File that must sit next to the tool for it to be usable at all. A
    /// candidate missing it is not a candidate.
    sibling: ?[]const u8 = null,
    install_hint: []const u8,
};

fn findSdkTool(b: *std.Build, options: SdkToolOptions) []const u8 {
    if (b.option([]const u8, options.option_name, options.option_description)) |path| {
        const resolved = requireTool(b, path, options.install_hint);
        if (options.sibling) |sibling| {
            _ = requireTool(b, siblingPath(b, resolved, sibling), options.install_hint);
        }
        return resolved;
    }
    if (b.graph.env_map.get(options.env_name)) |root| {
        const path = b.pathJoin(&.{ root, options.env_suffix });
        if (usableTool(b, path, options.sibling)) return path;
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
        if (!usableTool(b, candidate, options.sibling)) continue;
        if (newest_version == null or versionLessThan(newest_version.?, entry.name)) {
            newest_version = b.dupe(entry.name);
            newest_path = candidate;
        }
    }
    return newest_path orelse std.debug.panic("shader compiler not found: {s}", .{options.install_hint});
}

fn usableTool(b: *std.Build, path: []const u8, sibling: ?[]const u8) bool {
    if (!toolExists(path)) return false;
    const required = sibling orelse return true;
    return toolExists(siblingPath(b, path, required));
}

fn siblingPath(b: *std.Build, path: []const u8, name: []const u8) []const u8 {
    return b.pathJoin(&.{ std.fs.path.dirname(path) orelse ".", name });
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

fn findVulkanInclude(b: *std.Build) []const u8 {
    const install_hint = "install the LunarG Vulkan SDK or pass -Dvulkan-include-path=<path>";
    if (b.option([]const u8, "vulkan-include-path", "Path containing vulkan/vulkan.h")) |path| {
        return requireVulkanInclude(b, path, install_hint);
    }
    if (b.graph.env_map.get("VULKAN_SDK")) |root| {
        const path = b.pathJoin(&.{ root, "Include" });
        if (vulkanIncludeExists(b, path)) return path;
    }

    const search_root = "C:/VulkanSDK";
    var root = std.fs.openDirAbsolute(search_root, .{ .iterate = true }) catch {
        std.debug.panic("Vulkan headers not found: {s}", .{install_hint});
    };
    defer root.close();

    var newest_version: ?[]const u8 = null;
    var newest_path: ?[]const u8 = null;
    var iterator = root.iterate();
    while (iterator.next() catch @panic("failed to enumerate Vulkan SDK versions")) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = b.pathJoin(&.{ search_root, entry.name, "Include" });
        if (!vulkanIncludeExists(b, candidate)) continue;
        if (newest_version == null or versionLessThan(newest_version.?, entry.name)) {
            newest_version = b.dupe(entry.name);
            newest_path = candidate;
        }
    }
    return newest_path orelse std.debug.panic("Vulkan headers not found: {s}", .{install_hint});
}

fn requireVulkanInclude(b: *std.Build, path: []const u8, install_hint: []const u8) []const u8 {
    if (!vulkanIncludeExists(b, path)) {
        std.debug.panic("Vulkan headers not found under '{s}': {s}", .{ path, install_hint });
    }
    return b.dupe(path);
}

fn vulkanIncludeExists(b: *std.Build, path: []const u8) bool {
    return toolExists(b.pathJoin(&.{ path, "vulkan", "vulkan.h" }));
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
