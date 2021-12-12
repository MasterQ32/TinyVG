const std = @import("std");
const tvg = @import("tvg");
const args = @import("args");

fn printUsage(stream: anytype) !void {
    try stream.writeAll(
        \\tvg-render [-o file] [-g geometry] [-a] [-s <scale>] source.tvg
        \\
    );
}

const CliOptions = struct {
    help: bool = false,

    output: ?[]const u8 = null,

    geometry: ?Geometry = null,

    @"anti-alias": bool = false,
    @"super-sampling": ?u32 = null,

    pub const shorthands = .{
        .o = "output",
        .g = "geometry",
        .h = "help",
        .a = "anti-alias",
        .s = "super-sampling",
    };
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const cli = args.parseForCurrentProcess(CliOptions, allocator, .print) catch return 1;
    defer cli.deinit();

    // const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (cli.options.help) {
        try printUsage(stdout);
        return 0;
    }

    if (cli.positionals.len != 1) {
        try stderr.writeAll("Expected exactly one positional argument!\n");
        try printUsage(stderr);
        return 1;
    }

    const read_stdin = std.mem.eql(u8, cli.positionals[0], "-");
    const write_stdout = if (cli.options.output) |o|
        std.mem.eql(u8, o, "-")
    else
        false;

    if (read_stdin and cli.options.output == null) {
        try stderr.writeAll("Requires --output file name set when reading from stdin!\n");
        try printUsage(stderr);
        return 1;
    }

    var source_file: std.fs.File = if (read_stdin)
        std.io.getStdIn()
    else
        try std.fs.cwd().openFile(cli.positionals[0], .{});
    defer if (!read_stdin)
        source_file.close();

    var super_scale: u32 = 1;

    if (cli.options.@"anti-alias") {
        super_scale = 4;
    }
    if (cli.options.@"super-sampling") |scaling| {
        if (scaling == 0 or scaling > 32) {
            try stderr.writeAll("Superscaling is only allowed for scales between 1 and 32.\n");
            return 1;
        }
        super_scale = scaling;
    }

    // TODO: Render here

    var image = try tvg.rendering.renderStream(
        allocator,
        allocator,
        if (cli.options.geometry) |geom|
            tvg.rendering.SizeHint{ .size = tvg.rendering.Size{ .width = geom.width, .height = geom.height } }
        else
            .inherit,
        @intToEnum(tvg.rendering.AntiAliasing, super_scale),
        source_file.reader(),
    );
    defer image.deinit(allocator);

    for (image.pixels) |*c| {
        std.mem.swap(u8, &c.r, &c.b);
    }

    {
        const width = try std.math.cast(u16, image.width);
        const height = try std.math.cast(u16, image.height);

        var dest_file: std.fs.File = if (write_stdout)
            std.io.getStdIn()
        else blk: {
            var out_name = cli.options.output orelse try std.mem.concat(allocator, u8, &[_][]const u8{
                cli.positionals[0][0..(cli.positionals[0].len - std.fs.path.extension(cli.positionals[0]).len)],
                ".tga",
            });

            break :blk try std.fs.cwd().createFile(out_name, .{});
        };
        defer if (!read_stdin)
            dest_file.close();

        var writer = dest_file.writer();
        try dumpTga(writer, width, height, image.pixels);
    }

    return 0;
}

fn dumpTga(src_writer: anytype, width: u16, height: u16, pixels: []const tvg.rendering.Color8) !void {
    var buffered_writer = std.io.bufferedWriter(src_writer);
    var writer = buffered_writer.writer();

    std.debug.assert(pixels.len == @as(u32, width) * height);

    const image_id = "Hello, TGA!";

    try writer.writeIntLittle(u8, @intCast(u8, image_id.len));
    try writer.writeIntLittle(u8, 0); // color map type = no color map
    try writer.writeIntLittle(u8, 2); // image type = uncompressed true-color image
    // color map spec
    try writer.writeIntLittle(u16, 0); // first index
    try writer.writeIntLittle(u16, 0); // length
    try writer.writeIntLittle(u8, 0); // number of bits per pixel
    // image spec
    try writer.writeIntLittle(u16, 0); // x origin
    try writer.writeIntLittle(u16, 0); // y origin
    try writer.writeIntLittle(u16, width); // width
    try writer.writeIntLittle(u16, height); // height
    try writer.writeIntLittle(u8, 32); // bits per pixel
    try writer.writeIntLittle(u8, 8 | 0x20); // 0…3 => alpha channel depth = 8, 4…7 => direction=top left

    try writer.writeAll(image_id);
    try writer.writeAll(""); // color map data \o/
    try writer.writeAll(std.mem.sliceAsBytes(pixels));

    try buffered_writer.flush();
}

const Geometry = struct {
    const Self = @This();

    width: u32,
    height: u32,

    pub fn parse(str: []const u8) !Self {
        if (std.mem.indexOfScalar(u8, str, 'x')) |index| {
            return Geometry{
                .width = try std.fmt.parseInt(u32, str[0..index], 10),
                .height = try std.fmt.parseInt(u32, str[index + 1 ..], 10),
            };
        } else {
            const v = try std.fmt.parseInt(u32, str, 10);
            return Geometry{
                .width = v,
                .height = v,
            };
        }
    }
};
