const std = @import("std");

const Person = struct {
    name: []const u8,
    age: u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Stack allocation: Directly declared as a value
    const stack = Person{
        .name = "Mihalis",
        .age = 10,
    };
    std.debug.print(
        "Stack: N = {s}, A = {}\n",
        .{ stack.name, stack.age },
    );

    // Heap allocation: Using the allocator
    const heap_ptr = try allocator.create(Person);
    defer allocator.destroy(heap_ptr);

    // Dereference the pointer (.*) to assign the value
    heap_ptr.* = Person{
        .name = "Epifanios",
        .age = 18,
    };

    // Zig allows accessing fields on a pointer directly (syntactic sugar)
    std.debug.print(
        "Heap: N = {s}, A = {}\n",
        .{ heap_ptr.name, heap_ptr.age },
    );
}
