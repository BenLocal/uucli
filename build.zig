// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

const version = "0.0.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system_libdatachannel = b.option(
        bool,
        "system-libdatachannel",
        "Link a system libdatachannel instead of building it from source",
    ) orelse false;

    const exe = addUucli(b, target, optimize, system_libdatachannel);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run uucli").dependOn(&run_cmd.step);

    // Release archives (spec §11.3): zig-out/release/uucli-VERSION-ARCH-OS.tar.gz
    const release = b.step("release", "Build static release archives for Linux, macOS and Windows");
    // CI builds Linux on a Linux runner and macOS on a macOS runner (the macOS targets need the SDK).
    const release_os = b.option(std.Target.Os.Tag, "release-os", "Only build the release archives for this OS (linux, macos, windows)");
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };
    for (release_targets) |q| {
        if (release_os) |os| if (q.os_tag.? != os) continue;
        const t = b.resolveTargetQuery(q);
        const name = b.fmt("uucli-{s}-{s}-{s}", .{ version, @tagName(q.cpu_arch.?), @tagName(q.os_tag.?) });
        const rexe = addUucli(b, t, .ReleaseSafe, false);
        rexe.root_module.strip = true;
        const stage = b.addWriteFiles();
        const bin_name = if (q.os_tag.? == .windows) "uucli.exe" else "uucli";
        _ = stage.addCopyFile(rexe.getEmittedBin(), b.fmt("{s}/{s}", .{ name, bin_name }));
        for ([_][]const u8{ "README.md", "LICENSE", "NOTICE" }) |f|
            _ = stage.addCopyFile(b.path(f), b.fmt("{s}/{s}", .{ name, f }));
        if (q.os_tag.? != .windows)
            _ = stage.addCopyFile(b.path("contrib/systemd/uucli-portmap@.service"), b.fmt("{s}/contrib/systemd/uucli-portmap@.service", .{name}));
        const tar = b.addSystemCommand(&.{ "tar", "-C" });
        tar.addDirectoryArg(stage.getDirectory());
        tar.addArg("-czf");
        const archive = tar.addOutputFileArg(b.fmt("{s}.tar.gz", .{name}));
        tar.addArg(name);
        const install = b.addInstallFileWithDir(archive, .{ .custom = "release" }, b.fmt("{s}.tar.gz", .{name}));
        release.dependOn(&install.step);
    }

    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile unit and e2e tests without running").dependOn(&tests.step);
}

fn addUucli(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, system_libdatachannel: bool) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", options);
    const c = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    c.defineCMacro("RTC_STATIC", "1");
    linkNative(b, exe_mod, c, target, optimize, system_libdatachannel);
    exe_mod.addImport("c", c.createModule());
    // Golden vectors (tests/vectors), referenced only by tests.
    exe_mod.addImport("vectors", b.createModule(.{ .root_source_file = b.path("tests/vectors/vectors.zig") }));
    return b.addExecutable(.{ .name = "uucli", .root_module = exe_mod });
}

/// Adds the C/C++ libraries uucli calls into: libdatachannel (with its dependencies) and qrcodegen.
fn linkNative(
    b: *std.Build,
    m: *std.Build.Module,
    c: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    system_libdatachannel: bool,
) void {
    if (b.lazyDependency("qrcodegen", .{})) |dep| {
        c.addIncludePath(dep.path("c"));
        m.linkLibrary(cLibrary(b, "qrcodegen", target, optimize, dep.path("c"), &.{"qrcodegen.c"}, &.{}));
    }

    if (system_libdatachannel) {
        m.linkSystemLibrary("datachannel", .{});
        return;
    }

    const dc_dep = b.lazyDependency("libdatachannel", .{}) orelse return;
    const juice_dep = b.lazyDependency("libjuice", .{}) orelse return;
    const sctp_dep = b.lazyDependency("usrsctp", .{}) orelse return;
    const plog_dep = b.lazyDependency("plog", .{}) orelse return;
    const tls_dep = b.lazyDependency("mbedtls", .{}) orelse return;

    const os = target.result.os.tag;
    const quiet = &[_][]const u8{ "-w", "-fno-sanitize=undefined" };

    // Mbed TLS
    const tls = cLibrary(b, "mbedtls", target, optimize, tls_dep.path("library"), &mbedtls_sources, quiet);
    tls.root_module.addIncludePath(tls_dep.path("include"));
    tls.root_module.addIncludePath(tls_dep.path("library"));
    tls.root_module.addIncludePath(b.path("vendor/mbedtls"));
    tls.root_module.addCMacro("MBEDTLS_USER_CONFIG_FILE", "\"uucli_mbedtls_config.h\"");
    if (os == .windows) {
        tls.root_module.addCSourceFile(.{ .file = b.path("vendor/mbedtls/threading_win32.c"), .flags = quiet });
        tls.root_module.linkSystemLibrary("ws2_32", .{});
        tls.root_module.linkSystemLibrary("bcrypt", .{});
    }

    // usrsctp (no INET/INET6: libdatachannel only uses AF_CONN)
    const sctp = cLibrary(b, "usrsctp", target, optimize, sctp_dep.path("usrsctplib"), &usrsctp_sources, quiet);
    const sm = sctp.root_module;
    sm.addIncludePath(sctp_dep.path("usrsctplib"));
    for ([_][]const u8{ "__Userspace__", "SCTP_SIMPLE_ALLOCATOR", "SCTP_PROCESS_LEVEL_LOCKS", "HAVE_STDATOMIC_H" }) |name| sm.addCMacro(name, "1");
    switch (os) {
        .macos => {
            for ([_][]const u8{ "__APPLE_USE_RFC_2292", "HAVE_SYS_QUEUE_H", "HAVE_SA_LEN", "HAVE_SIN_LEN", "HAVE_SIN6_LEN", "HAVE_SCONN_LEN", "HAVE_NETINET_IP_ICMP_H", "HAVE_NET_ROUTE_H" }) |name| sm.addCMacro(name, "1");
        },
        .linux => {
            for ([_][]const u8{ "_GNU_SOURCE", "HAVE_LINUX_IF_ADDR_H", "HAVE_LINUX_RTNETLINK_H", "HAVE_NETINET_IP_ICMP_H", "HAVE_NET_ROUTE_H" }) |name| sm.addCMacro(name, "1");
            if (!target.result.isMuslLibC()) sm.addCMacro("HAVE_SYS_QUEUE_H", "1");
        },
        .windows => {
            sm.addCMacro("_WIN32_WINNT", "0x0601");
            sm.addCMacro("__USE_MINGW_ANSI_STDIO", "1");
            sm.addCMacro("WIN32_LEAN_AND_MEAN", "1");
            sm.linkSystemLibrary("ws2_32", .{});
            sm.linkSystemLibrary("iphlpapi", .{});
        },
        else => {},
    }

    // libjuice (ICE/STUN/TURN)
    const juice = cLibrary(b, "juice", target, optimize, juice_dep.path("src"), &juice_sources, quiet);
    const jm = juice.root_module;
    jm.addIncludePath(juice_dep.path("include"));
    jm.addIncludePath(juice_dep.path("include/juice"));
    jm.addIncludePath(juice_dep.path("src"));
    jm.addCMacro("JUICE_STATIC", "1");
    jm.addCMacro("JUICE_EXPORTS", "1");
    jm.addCMacro("USE_NETTLE", "0");
    jm.addCMacro("NO_SERVER", "1");
    if (os == .windows) {
        jm.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        jm.addCMacro("_WIN32_WINNT", "0x0601");
        jm.linkSystemLibrary("ws2_32", .{});
        jm.linkSystemLibrary("bcrypt", .{});
    }

    // libdatachannel (data channels only: no media, no WebSocket)
    const dc_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    addMacSdk(b, dc_mod, target);
    dc_mod.addCSourceFiles(.{
        .root = dc_dep.path("src"),
        .files = &datachannel_sources,
        .flags = &.{ "-std=c++17", "-w", "-fno-sanitize=undefined" },
    });
    for ([_]std.Build.LazyPath{
        dc_dep.path("include"),
        dc_dep.path("include/rtc"),
        dc_dep.path("src"),
        plog_dep.path("include"),
        sctp_dep.path("usrsctplib"),
        juice_dep.path("include"),
        tls_dep.path("include"),
        b.path("vendor/mbedtls"),
    }) |p| dc_mod.addIncludePath(p);
    for ([_][2][]const u8{
        .{ "RTC_STATIC", "1" },                                        .{ "RTC_EXPORTS", "1" },
        .{ "RTC_ENABLE_WEBSOCKET", "0" },                              .{ "RTC_ENABLE_MEDIA", "0" },
        .{ "RTC_SYSTEM_JUICE", "0" },                                  .{ "RTC_SYSTEM_SRTP", "0" },
        .{ "USE_NICE", "0" },                                          .{ "USE_GNUTLS", "0" },
        .{ "USE_MBEDTLS", "1" },                                       .{ "JUICE_STATIC", "1" },
        .{ "MBEDTLS_USER_CONFIG_FILE", "\"uucli_mbedtls_config.h\"" },
    }) |d| dc_mod.addCMacro(d[0], d[1]);
    // usrsctp.h gives struct sockaddr_conn a length byte on BSD-style systems; libdatachannel must fill it.
    if (os.isDarwin()) dc_mod.addCMacro("HAVE_SCONN_LEN", "1");
    if (os == .windows) {
        dc_mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        dc_mod.addCMacro("NOMINMAX", "1");
        dc_mod.addCMacro("_WIN32_WINNT", "0x0601");
        dc_mod.linkSystemLibrary("ws2_32", .{});
        dc_mod.linkSystemLibrary("crypt32", .{});
    }
    dc_mod.linkLibrary(juice);
    dc_mod.linkLibrary(sctp);
    dc_mod.linkLibrary(tls);
    const dc = b.addLibrary(.{ .name = "datachannel", .root_module = dc_mod });

    m.link_libcpp = true;
    c.addIncludePath(dc_dep.path("include"));
    m.linkLibrary(dc);
    if (os == .windows) {
        m.linkSystemLibrary("ws2_32", .{});
        m.linkSystemLibrary("iphlpapi", .{});
        m.linkSystemLibrary("bcrypt", .{});
        m.linkSystemLibrary("crypt32", .{});
    }
}

/// An explicit macOS target (the release step) does not get the SDK headers a native build gets;
/// usrsctp needs some that Zig does not ship (netinet/ip_icmp.h). Needs a macOS host with the SDK.
fn addMacSdk(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos or target.query.isNative()) return;
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse return;
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
}

fn cLibrary(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: std.Build.LazyPath,
    files: []const []const u8,
    flags: []const []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    addMacSdk(b, mod, target);
    mod.addCSourceFiles(.{ .root = root, .files = files, .flags = flags });
    return b.addLibrary(.{ .name = name, .root_module = mod });
}

const datachannel_sources = [_][]const u8{
    "candidate.cpp",                 "channel.cpp",                 "configuration.cpp",
    "datachannel.cpp",               "dependencydescriptor.cpp",    "description.cpp",
    "iceudpmuxlistener.cpp",         "mediahandler.cpp",            "global.cpp",
    "message.cpp",                   "peerconnection.cpp",          "rtcpreceivingsession.cpp",
    "track.cpp",                     "websocket.cpp",               "websocketserver.cpp",
    "rtppacketizationconfig.cpp",    "rtcpsrreporter.cpp",          "rtppacketizer.cpp",
    "rtpdepacketizer.cpp",           "h264rtppacketizer.cpp",       "h264rtpdepacketizer.cpp",
    "nalunit.cpp",                   "h265rtppacketizer.cpp",       "h265rtpdepacketizer.cpp",
    "h265nalunit.cpp",               "av1rtppacketizer.cpp",        "rtcpnackresponder.cpp",
    "rtp.cpp",                       "capi.cpp",                    "plihandler.cpp",
    "pacinghandler.cpp",             "rembhandler.cpp",             "impl/certificate.cpp",
    "impl/channel.cpp",              "impl/datachannel.cpp",        "impl/dtlssrtptransport.cpp",
    "impl/dtlstransport.cpp",        "impl/icetransport.cpp",       "impl/iceudpmuxlistener.cpp",
    "impl/init.cpp",                 "impl/peerconnection.cpp",     "impl/logcounter.cpp",
    "impl/sctptransport.cpp",        "impl/threadpool.cpp",         "impl/tls.cpp",
    "impl/track.cpp",                "impl/utils.cpp",              "impl/processor.cpp",
    "impl/sha.cpp",                  "impl/pollinterrupter.cpp",    "impl/pollservice.cpp",
    "impl/http.cpp",                 "impl/httpproxytransport.cpp", "impl/tcpserver.cpp",
    "impl/tcptransport.cpp",         "impl/tlstransport.cpp",       "impl/transport.cpp",
    "impl/verifiedtlstransport.cpp", "impl/websocket.cpp",          "impl/websocketserver.cpp",
    "impl/wstransport.cpp",          "impl/wshandshake.cpp",
};

const juice_sources = [_][]const u8{
    "addr.c",      "agent.c",       "crc32.c",     "const_time.c", "conn.c",
    "conn_poll.c", "conn_thread.c", "conn_mux.c",  "base64.c",     "hash.c",
    "hmac.c",      "ice.c",         "juice.c",     "log.c",        "random.c",
    "server.c",    "stun.c",        "timestamp.c", "tcp.c",        "turn.c",
    "udp.c",
};

const usrsctp_sources = [_][]const u8{
    "netinet/sctp_asconf.c",       "netinet/sctp_auth.c",         "netinet/sctp_bsd_addr.c",
    "netinet/sctp_callout.c",      "netinet/sctp_cc_functions.c", "netinet/sctp_crc32.c",
    "netinet/sctp_indata.c",       "netinet/sctp_input.c",        "netinet/sctp_output.c",
    "netinet/sctp_pcb.c",          "netinet/sctp_peeloff.c",      "netinet/sctp_sha1.c",
    "netinet/sctp_ss_functions.c", "netinet/sctp_sysctl.c",       "netinet/sctp_timer.c",
    "netinet/sctp_userspace.c",    "netinet/sctp_usrreq.c",       "netinet/sctputil.c",
    "netinet6/sctp6_usrreq.c",     "user_environment.c",          "user_mbuf.c",
    "user_recv_thread.c",          "user_socket.c",
};

const mbedtls_sources = [_][]const u8{
    "aes.c",                         "aesce.c",               "aesni.c",
    "aria.c",                        "asn1parse.c",           "asn1write.c",
    "base64.c",                      "bignum_core.c",         "bignum_mod_raw.c",
    "bignum_mod.c",                  "bignum.c",              "block_cipher.c",
    "camellia.c",                    "ccm.c",                 "chacha20.c",
    "chachapoly.c",                  "cipher_wrap.c",         "cipher.c",
    "cmac.c",                        "constant_time.c",       "ctr_drbg.c",
    "debug.c",                       "des.c",                 "dhm.c",
    "ecdh.c",                        "ecdsa.c",               "ecjpake.c",
    "ecp_curves_new.c",              "ecp_curves.c",          "ecp.c",
    "entropy_poll.c",                "entropy.c",             "error.c",
    "gcm.c",                         "hkdf.c",                "hmac_drbg.c",
    "lmots.c",                       "lms.c",                 "md.c",
    "md5.c",                         "memory_buffer_alloc.c", "mps_reader.c",
    "mps_trace.c",                   "net_sockets.c",         "nist_kw.c",
    "oid.c",                         "padlock.c",             "pem.c",
    "pk_ecc.c",                      "pk_wrap.c",             "pk.c",
    "pkcs12.c",                      "pkcs5.c",               "pkcs7.c",
    "pkparse.c",                     "pkwrite.c",             "platform_util.c",
    "platform.c",                    "poly1305.c",            "psa_crypto_aead.c",
    "psa_crypto_cipher.c",           "psa_crypto_client.c",   "psa_crypto_driver_wrappers_no_static.c",
    "psa_crypto_ecp.c",              "psa_crypto_ffdh.c",     "psa_crypto_hash.c",
    "psa_crypto_mac.c",              "psa_crypto_pake.c",     "psa_crypto_random.c",
    "psa_crypto_rsa.c",              "psa_crypto_se.c",       "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",          "psa_crypto.c",          "psa_its_file.c",
    "psa_util.c",                    "ripemd160.c",           "rsa_alt_helpers.c",
    "rsa.c",                         "sha1.c",                "sha256.c",
    "sha3.c",                        "sha512.c",              "ssl_cache.c",
    "ssl_ciphersuites.c",            "ssl_client.c",          "ssl_cookie.c",
    "ssl_debug_helpers_generated.c", "ssl_msg.c",             "ssl_ticket.c",
    "ssl_tls.c",                     "ssl_tls12_client.c",    "ssl_tls12_server.c",
    "ssl_tls13_client.c",            "ssl_tls13_generic.c",   "ssl_tls13_keys.c",
    "ssl_tls13_server.c",            "threading.c",           "timing.c",
    "version_features.c",            "version.c",             "x509_create.c",
    "x509_crl.c",                    "x509_crt.c",            "x509_csr.c",
    "x509.c",                        "x509write_crt.c",       "x509write_csr.c",
    "x509write.c",
};
