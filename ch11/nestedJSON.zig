const std = @import("std");

const Address = struct {
    street: []const u8,
    city: []const u8,
    postal: []const u8,

    pub fn print(self: Address) void {
        std.debug.print("  Street: {s}\n", .{self.street});
        std.debug.print("  City:   {s}\n", .{self.city});
        std.debug.print("  Postal: {s}\n", .{self.postal});
    }
};

const Person = struct {
    id: u32,
    name: []const u8,
    address: Address,

    pub fn print(self: Person) void {
        std.debug.print("ID: {}\n", .{self.id});
        std.debug.print("Name: {s}\n", .{self.name});
        std.debug.print("Address:\n", .{});
        self.address.print();
        std.debug.print("\n", .{});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <jsonFile>\n", .{args[0]});
        return error.MissingFilename;
    }

    const fp = args[1];
    const file = std.Io.Dir.cwd().openFile(io, fp, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("File not found: {s}\n", .{fp});
            },
            else => {
                std.debug.print(
                    "Failed to open file {s}: {}\n",
                    .{ fp, err },
                );
            },
        }
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const contents = try allocator.alloc(u8, stat.size);
    defer allocator.free(contents);

    _ = try file.readPositionalAll(io, contents, 0);
    var parsed = try std.json.parseFromSlice(
        []Person,
        allocator,
        contents,
        .{},
    );
    defer parsed.deinit();

    for (parsed.value) |person| {
        person.print();
    }
}
