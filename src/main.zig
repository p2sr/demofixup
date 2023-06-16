const std = @import("std");

fn err(comptime fmt: []const u8, args: anytype) u8 {
    std.io.getStdErr().writer().print(fmt ++ "\n", args) catch {};
    return 1;
}

fn countDirFiles(dir: std.fs.IterableDir, ally: std.mem.Allocator) !u32 {
    var walker = try dir.walk(ally);
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |ent| {
        if (ent.kind == .file) {
            count += 1;
        }
    }

    return count;
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const args = std.process.argsAlloc(ally) catch return err("oom", .{});
    if (args.len < 2) {}

    var in_name: ?[]const u8 = null;
    var out_name: ?[]const u8 = null;
    var inplace: bool = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-I")) {
            inplace = true;
        } else if (in_name == null) {
            in_name = arg;
        } else if (out_name == null) {
            out_name = arg;
        } else {
            return err("unrecognised argument {s}", .{arg});
        }
    }

    if (in_name == null) {
        return err(
            \\usage: {s} [options] <in name> [out name]
            \\options:
            \\    -I   modify files inplace
        ,
            .{if (args.len > 0) args[0] else "demofixup"},
        );
    }

    if (inplace) {
        if (out_name != null) {
            return err("cannot specify output dir with -I", .{});
        } else {
            out_name = in_name;
        }
    } else if (out_name == null) {
        if (std.mem.endsWith(u8, in_name.?, ".dem") or std.mem.endsWith(u8, in_name.?, ".DEM")) {
            out_name = std.fmt.allocPrint(ally, "{s}_fixed.dem", .{in_name.?[0 .. in_name.?.len - 4]}) catch return err("out of memory", .{});
        } else {
            out_name = std.fmt.allocPrint(ally, "{s}_fixed", .{std.mem.trimRight(u8, in_name.?, "/\\")}) catch return err("out of memory", .{});
        }
    }

    const kind: std.fs.File.Kind = if (std.fs.cwd().statFile(in_name.?)) |stat| stat.kind else |e| switch (e) {
        error.IsDir => .directory,
        else => return err("error on stat {s}: {}", .{ in_name.?, e }),
    };
    switch (kind) {
        .file => {
            var progress: std.Progress = .{};

            const root_prog_node = progress.start("run fixup", 1);
            defer root_prog_node.end();

            fixupFile(ally, root_prog_node, std.fs.cwd(), std.fs.cwd(), in_name.?, out_name.?) catch |e| {
                std.io.getStdOut().writer().print("failed to fixup {s}: {}", .{ in_name.?, e }) catch {};
                return 1;
            };

            std.io.getStdOut().writer().print("successfully wrote {s}!\n", .{out_name.?}) catch {};
        },
        .directory => {
            var in_dir = std.fs.cwd().openIterableDir(in_name.?, .{}) catch |e| return err("failed to open dir {s}: {}", .{ in_name.?, e });
            defer in_dir.close();

            var out_dir = std.fs.cwd().makeOpenPath(out_name.?, .{}) catch |e| return err("failed to open dir {s}: {}", .{ out_name.?, e });
            defer out_dir.close();

            var failed = std.ArrayList([]const u8).init(ally);

            switch (fixupDir(in_dir, out_dir, &failed, ally)) {
                0 => {},
                else => |ret| return ret,
            }

            std.io.getStdOut().writer().print("successfully wrote directory {s}!\n", .{out_name.?}) catch {};

            if (failed.items.len > 0) {
                std.io.getStdOut().writer().print("failed demos:\n", .{}) catch {};
                for (failed.items) |fail| {
                    std.io.getStdOut().writer().print("    {s}\n", .{fail}) catch {};
                }
            }
        },
        else => |k| return err("bad file kind: {}", .{k}),
    }

    return 0;
}

fn fixupDir(
    in_dir: std.fs.IterableDir,
    out_dir: std.fs.Dir,
    failed: *std.ArrayList([]const u8),
    main_arena: std.mem.Allocator,
) u8 {
    const demo_count = countDirFiles(in_dir, main_arena) catch 0;

    var progress: std.Progress = .{};

    const root_prog_node = progress.start("run fixup", demo_count);
    defer root_prog_node.end();

    var dem_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer dem_arena.deinit();

    var walker = in_dir.walk(main_arena) catch |e| return err("failed to walk dir: {}", .{e});
    defer walker.deinit();

    while (walker.next() catch |e| return err("failed to iterate dir: {}", .{e})) |ent| {
        if (ent.kind != .file) continue;

        // create the output dir
        if (std.fs.path.dirname(ent.path)) |dirname| {
            out_dir.makePath(dirname) catch |e| return err("failed to make out dir {s}: {}", .{ dirname, e });
        }

        fixupFile(dem_arena.allocator(), root_prog_node, in_dir.dir, out_dir, ent.path, ent.path) catch |e| {
            const str = std.fmt.allocPrint(main_arena, "{s}: {}", .{ ent.path, e }) catch return err("out of memory", .{});
            failed.append(str) catch return err("out of memory", .{});
        };

        _ = dem_arena.reset(.retain_capacity);
    }

    return 0;
}

fn fixupFile(
    dem_arena: std.mem.Allocator,
    root_prog_node: *std.Progress.Node,
    in_dir: std.fs.Dir,
    out_dir: std.fs.Dir,
    in_name: []const u8,
    out_name: []const u8,
) !void {
    if (std.fs.path.dirname(out_name)) |dirname| {
        try out_dir.makePath(dirname);
    }

    var in_data = try in_dir.readFileAlloc(dem_arena, in_name, 100_000_000);

    var out_file = try out_dir.atomicFile(out_name, .{});
    defer out_file.deinit();

    {
        var prog_node = root_prog_node.start("process demo", 1);
        defer prog_node.end();
        try fixupDemo(in_data, &out_file.file, dem_arena);
    }

    try out_file.finish();
}

fn fixupDemo(in_data: []const u8, out_file: *std.fs.File, ally: std.mem.Allocator) !void {
    var buf_rd = std.io.fixedBufferStream(in_data);
    var buf_wr = std.io.bufferedWriter(out_file.writer());

    const in_rd = buf_rd.reader();
    const out_wr = buf_wr.writer();

    try clone(in_rd, out_wr, 1072); // demo header

    while (true) {
        const kind = try in_rd.readByte();
        try out_wr.writeByte(kind);
        try clone(in_rd, out_wr, 5);
        switch (kind) {
            1, 2 => { // signon, packet
                try clone(in_rd, out_wr, 76 * 2 + 8);
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                try clone(in_rd, out_wr, size);
            },
            3 => {}, // synctick
            4 => { // consolecmd
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                try clone(in_rd, out_wr, size);
            },
            5 => { // usercmd
                try clone(in_rd, out_wr, 4); // cmd
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                try clone(in_rd, out_wr, size);
            },
            6 => { // datatables
                // oh boy 3am!!!
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                var count_rd = std.io.countingReader(in_rd);
                var count_wr = std.io.countingWriter(out_wr);
                try doDataTableStuff(count_rd.reader(), count_wr.writer(), ally);
                try in_rd.skipBytes(size - count_rd.bytes_read, .{});
                const to_pad = size - count_wr.bytes_written;
                for (0..to_pad) |_| {
                    try out_wr.writeByte(0);
                }
            },
            7 => { // stop
                break;
            },
            8 => { // customdata
                try clone(in_rd, out_wr, 4); // type
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                try clone(in_rd, out_wr, size);
            },
            9 => { // stringtables
                const size = try in_rd.readIntLittle(u32);
                try out_wr.writeIntLittle(u32, size);
                try clone(in_rd, out_wr, size);
            },
            else => return error.BadDemo,
        }
    }

    // write all remaining data
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(in_rd, out_wr);

    try buf_wr.flush();
}

fn clone(in: anytype, out: anytype, n: usize) !void {
    var buf: [64]u8 = undefined;
    var rem = n;
    while (rem > 64) {
        try in.readNoEof(&buf);
        try out.writeAll(&buf);
        rem -= 64;
    }
    try in.readNoEof(buf[0..rem]);
    try out.writeAll(buf[0..rem]);
}

fn cloneBits(br: anytype, bw: anytype, n: usize) !void {
    var buf: [8]u8 = undefined;
    var rem = n;
    while (rem > 64) {
        try br.reader().readNoEof(&buf);
        try bw.writer().writeAll(&buf);
        rem -= 64;
    }
    const x = try br.readBitsNoEof(u64, rem);
    try bw.writeBits(x, rem);
}

fn doDataTableStuff(in_rd: anytype, out_wr: anytype, ally: std.mem.Allocator) !void {
    var br_l = std.io.bitReader(.Little, in_rd);
    var bw_l = std.io.bitWriter(.Little, out_wr);
    const br = &br_l;
    const bw = &bw_l;

    // write out sendtables but remove bad one
    while (try readBool(br)) {
        const needs_dec = try readBool(br);
        const table_name = try readStr(br, ally);
        const num_props = try br.readBitsNoEof(u10, 10);

        const skip = std.mem.eql(u8, table_name, "DT_PointSurvey\x00");

        if (!skip) {
            try bw.writeBits(@as(u1, 1), 1); // presence bit
            try bw.writeBits(@boolToInt(needs_dec), 1);
            try bw.writer().writeAll(table_name);
            try bw.writeBits(num_props, 10);
        }

        for (0..num_props) |_| {
            const prop_ty = try br.readBitsNoEof(u5, 5);
            const prop_name = try readStr(br, ally);
            const prop_flags = try br.readBitsNoEof(u19, 19);
            const prop_priority = try br.readBitsNoEof(u8, 8);

            if (!skip) {
                try bw.writeBits(prop_ty, 5);
                try bw.writer().writeAll(prop_name);
                try bw.writeBits(prop_flags, 19);
                try bw.writeBits(prop_priority, 8);
            }

            if (prop_ty == 6 or prop_flags & (1 << 6) != 0) {
                const exclude_name = try readStr(br, ally);
                if (!skip) {
                    try bw.writer().writeAll(exclude_name);
                }
            } else {
                const extra_len: usize = switch (prop_ty) {
                    0...4 => 64 + 7,
                    5 => 10, // array
                    else => @panic("bad sendtable prop type"),
                };

                if (!skip) {
                    try cloneBits(br, bw, extra_len);
                } else {
                    _ = try br.readBitsNoEof(u128, extra_len);
                }
            }
        }
    }

    try bw.writeBits(@as(u1, 0), 1);

    // write out the classes but replace the bad one with a dummy entry
    const num_classes = try br.readBitsNoEof(u16, 16);
    try bw.writeBits(num_classes, 16);
    for (0..num_classes) |_| {
        const class_id = try br.readBitsNoEof(u16, 16);
        const class_name = try readStr(br, ally);
        const dt_name = try readStr(br, ally);
        if (std.mem.eql(u8, dt_name, "DT_PointSurvey\x00")) {
            if (!std.mem.eql(u8, class_name, "CPointSurvey\x00")) {
                @panic("bad class name using DT_PointSurvey");
            }
            try bw.writeBits(class_id, 16);
            try bw.writer().writeAll("CPointCamera\x00");
            try bw.writer().writeAll("DT_PointCamera\x00");
        } else {
            try bw.writeBits(class_id, 16);
            try bw.writer().writeAll(class_name);
            try bw.writer().writeAll(dt_name);
        }
    }
}

fn readBool(br: anytype) !bool {
    const x = try br.readBitsNoEof(u1, 1);
    return x == 1;
}

fn readStr(br: anytype, ally: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(ally);
    while (true) {
        const c = try br.reader().readByte();
        try buf.append(c);
        if (c == 0) break;
    }
    return buf.toOwnedSlice();
}
