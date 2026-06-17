const std = @import("std");
const Io = std.Io;

const Person = packed struct(u16) {
    age: u8,
    value: u8,
};

pub fn main(_: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    const p: Person = .{ .age = 20, .value = 100 };

    var writer_state: Io.Writer.Allocating = .init(gpa);
    const w = &writer_state.writer;

    try w.writeInt(u16, @bitCast(p), .little);
    std.debug.print("Written: {any}\n", .{writer_state.written()});

    var reader: Io.Reader = .fixed(writer_state.written());
    const readP: Person = @bitCast(try reader.takeInt(u16, .little));
    std.debug.print("Read: {any}\n", .{readP});
}
