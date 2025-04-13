const std = @import("std");
const print = std.debug.print;

const Self = @This();

// === SM83 ===
const Flags = enum(u8) {
    Zero = 1 << 7,
    Subtract = 1 << 6,
    HalfCarry = 1 << 5,
    Carry = 1 << 4,
};
const Condition = enum(u2) {
    NotZero = 0b00, // JP NZ, nn
    Zero = 0b01, // JP Z, nn
    NotCarry = 0b10, // JP NC, nn
    Carry = 0b11, // JP C, nn
};
const RstVector = enum(u16) {
    Rst1 = 0x00,
    Rst2 = 0x08,
    Rst3 = 0x10,
    Rst4 = 0x18,
    Rst5 = 0x20,
    Rst6 = 0x28,
    Rst7 = 0x30,
    Rst8 = 0x38,
};
const Bit = enum(u8) {
    Bit0 = 0b00000001,
    Bit1 = 0b00000010,
    Bit2 = 0b00000100,
    Bit3 = 0b00001000,
    Bit4 = 0b00010000,
    Bit5 = 0b00100000,
    Bit6 = 0b01000000,
    Bit7 = 0b10000000,
};

const REG_A: u8 = 0;
const REG_B: u8 = 1;
const REG_C: u8 = 2;
const REG_D: u8 = 3;
const REG_E: u8 = 4;
const REG_H: u8 = 5;
const REG_L: u8 = 6;
const REG_F: u8 = 7;

// 8-bit 7 General Purpose registers (A,B,C,D,H,L)
// 8-bit flags register (F)
registers: [8]u8,

// Memory Map
// 0x0000 - 0x7FFF: External Bus (ROM region)
// 0x8000 - 0x9FFF: VRAM
// 0xA000 - 0xBFFF: External Bus (RAM region)
// 0xC000 - 0xDFFF: WRAM
// 0xE000 - 0xFDFF: ECHO (WRAM secondary mapping)
// 0xFE00 - 0xFE9F: Object Attribute Memory (OAM)
// 0xFEA0 - 0xFEFF: Invalid OAM region (behavior varies per revision)
// 0xFF00 - 0xFF7F: Memory mapped I/O
// 0xFF80 - 0xFFFE: High RAM (HRAM)
// 0xFFFF: IE (register)
memory: [0x10000]u8,

graphics: [160 * 144]u8,

// Current Operation Code
current_opcode: u16,
unimplemented_opcode: u16,

// Program Counter and Stack Pointer
program_counter: u16,
stack_pointer: u16,

// Clock cycles for timing
cycles: u64,

// Whether interrupts are enabled
ime: bool = false,
halted: bool = false,

// === SM83 ===
pub fn println(msg: []const u8) void {
    print("{s}\n", .{msg});
}
pub fn debug(self: *Self) void {
    // Clear screen and print header
    print("\x1B[2J\x1B[H", .{});
    print("\n=== EMU STATE ===\n", .{});
    print("Program Counter      :    0x{X:0>4}\n", .{self.program_counter});
    print("Stack Pointer        :    0x{X:0>4}\n", .{self.stack_pointer});
    // Print register values
    print("\n=== REGISTERS ===\n", .{});
    // Loop through registers A to L
    const register_names: []const u8 = "ABCDEHLF";

    for (register_names, 0..8) |r, idx| {
        print("{c}: 0x{X:0>4}\n", .{ r, self.registers[idx] });
    }
    // Print combined 16-bit registers
    print("\n=== 16-BIT REGISTERS ===\n", .{});
    print("AF: 0x{X:0>4}\n", .{self.get_af()});
    print("BC: 0x{X:0>4}\n", .{self.get_bc()});
    print("DE: 0x{X:0>4}\n", .{self.get_de()});
    print("HL: 0x{X:0>4}\n", .{self.get_hl()});
    print("Unimplemented opcode: 0x{x}\n", .{self.unimplemented_opcode});
}
// Graphics
pub fn getPixel(self: *Self, x: u8, y: u8) u32 {
    if (x >= 160 or y >= 144) return 0x000000;

    const lcd_control = self.read_byte(0xFF40);
    const bgp = self.read_byte(0xFF47);

    const tile_map_addr: u16 = if ((lcd_control & 0x08) != 0) 0x9C00 else 0x9800;
    const tile_x = @as(u16, x) / 8;
    const tile_y = @as(u16, y) / 8;
    const tile_index_addr = tile_map_addr + tile_y * 32 + tile_x;

    const tile_index = self.read_byte(tile_index_addr);
    const tile_data_base: u16 = if ((lcd_control & 0x10) != 0) 0x8000 else 0x8800;

    var tile_addr: u16 = undefined;
    if (tile_data_base == 0x8800) {
        const signed_index = @as(i16, @intCast(@as(i8, @bitCast(tile_index))));
        tile_addr = @as(u16, @intCast(signed_index + 128)) * 16 + 0x8000;
    } else {
        tile_addr = @as(u16, tile_index) * 16 + 0x8000;
    }

    const row = @as(u16, y % 8) * 2;

    const low_byte = self.read_byte(tile_addr + row);
    const high_byte = self.read_byte(tile_addr + row + 1);

    const bit_index = @as(u3, 7 - @as(u3, @intCast(x % 8)));
    const color_id = (((high_byte >> bit_index) & 1) << 1) | ((low_byte >> bit_index) & 1);
    const color = (bgp >> (@as(u3, @intCast(color_id)) * 2)) & 0x03;

    return switch (color) {
        0 => 0xFFFFFF, // White
        1 => 0xAAAAAA, // Light Gray
        2 => 0x555555, // Dark Gray
        3 => 0x000000, // Black
        else => unreachable,
    };
}
// Jump
fn jump(self: *Self, addr: u16) void {
    self.program_counter = addr;
}
fn jump_rel(self: *Self, offset: i8) void {
    const signed_offset: i16 = @as(i16, offset);
    const addr: u16 = @intCast(@as(i16, @intCast(self.program_counter)) + signed_offset);
    self.jump(addr);
}
fn jump_rel_if(self: *Self, offset: i8, condition: Self.Condition) void {
    const signed_offset: i16 = @as(i16, offset);
    const addr: u16 = @intCast(@as(i16, @intCast(self.program_counter)) + signed_offset);
    switch (condition) {
        Condition.NotZero => { // JP NZ
            if (!self.get_flag(.Zero)) {
                self.jump(addr);
            }
        },
        Condition.Zero => { // JP Z
            if (self.get_flag(.Zero)) {
                self.jump(addr);
            }
        },
        Condition.NotCarry => { // JP NC
            if (!self.get_flag(.Carry)) {
                self.jump(addr);
            }
        },
        Condition.Carry => { // JP C
            if (self.get_flag(.Carry)) {
                self.jump(addr);
            }
        },
    }
}
fn jump_if(self: *Self, addr: u16, condition: Self.Condition) void {
    switch (condition) {
        Condition.NotZero => { // JP NZ
            if (!self.get_flag(.Zero)) {
                self.jump(addr);
            }
        },
        Condition.Zero => { // JP Z
            if (self.get_flag(.Zero)) {
                self.jump(addr);
            }
        },
        Condition.NotCarry => { // JP NC
            if (!self.get_flag(.Carry)) {
                self.jump(addr);
            }
        },
        Condition.Carry => { // JP C
            if (self.get_flag(.Carry)) {
                self.jump(addr);
            }
        },
    }
}
// Call
fn call(self: *Self, source: u16) void {
    const pc = self.program_counter;
    self.push(pc);
    self.program_counter = source;
}
fn rst(self: *Self, vector: RstVector) void {
    const source = @intFromEnum(vector);
    self.call(source);
}
fn ret(self: *Self) void {
    const pc = self.pop();
    self.program_counter = pc;
}
fn ret_if(self: *Self, condition: Condition) void {
    switch (condition) {
        .NotZero => { // CALL NZ
            if (!self.get_flag(.Zero)) {
                self.ret();
            }
        },
        .Zero => { // CALL Z
            if (self.get_flag(.Zero)) {
                self.ret();
            }
        },
        .NotCarry => { // CALL NC
            if (!self.get_flag(.Carry)) {
                self.ret();
            }
        },
        .Carry => { // CALL C
            if (self.get_flag(.Carry)) {
                self.ret();
            }
        },
    }
}
// 8-bit Rotate/Shift operations
// !! TODO
// Arithmetic
pub fn add_u8(self: *Self, value: u8, use_carry: bool) void {
    const a: u8 = self.registers[REG_A];
    const carry: u8 = if (use_carry and self.get_flag(.Carry)) 1 else 0;
    const result: u8 = a +% value +% carry;

    // Set flags
    self.set_flag(.Zero, result == 0);
    self.set_flag(.Subtract, false);
    self.set_flag(.HalfCarry, (a & 0xF) + (value & 0xF) + carry > 0xF);
    self.set_flag(.Carry, @as(u16, @intCast(a)) + @as(u16, @intCast(value)) + carry > 0xFF);

    // Store result back in A
    self.registers[REG_A] = result;
}
pub fn sub_u8(self: *Self, value: u8, use_carry: bool) void {
    const a: u8 = self.registers[REG_A];
    const carry: u8 = if (use_carry and self.get_flag(.Carry)) 1 else 0;
    const result: u8 = a -% value -% carry;

    // Set flags
    self.set_flag(.Zero, result == 0);
    self.set_flag(.Subtract, true);
    self.set_flag(.HalfCarry, (a & 0xF) < (value & 0xF) + carry);
    self.set_flag(.Carry, @as(u16, @intCast(a)) < @as(u16, @intCast(value)) + carry);

    // Store result back in A
    self.registers[REG_A] = result;
}
pub fn and_u8(self: *Self, n: u8) void {
    const result = self.registers[REG_A] & n;
    self.set_flag(.Carry, false);
    self.set_flag(.HalfCarry, true);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, (result == 0));
    self.registers[REG_A] = result;
}
pub fn or_u8(self: *Self, n: u8) void {
    const result = self.registers[REG_A] | n;
    self.set_flag(Flags.Carry, false);
    self.set_flag(Flags.HalfCarry, false);
    self.set_flag(Flags.Subtract, false);
    self.set_flag(Flags.Zero, (result == 0));
    self.registers[REG_A] = result;
}
pub fn xor_u8(self: *Self, n: u8) void {
    const result = self.registers[REG_A] ^ n;
    self.set_flag(Flags.Carry, false);
    self.set_flag(Flags.HalfCarry, false);
    self.set_flag(Flags.Subtract, false);
    self.set_flag(Flags.Zero, (result == 0));
    self.registers[REG_A] = result;
}
pub fn cmp_u8(self: *Self, n: u8) void {
    const a = self.registers[REG_A];
    self.sub_u8(n, false);
    self.registers[REG_A] = a;
}
pub fn inc_u8(self: *Self, n: u8) u8 {
    const result = n +% 1;
    const half_carry = ((n & 0xF) + 1) > 0xF;

    self.set_flag(Flags.HalfCarry, half_carry);
    self.set_flag(Flags.Subtract, false);
    self.set_flag(Flags.Zero, (result == 0));

    return result;
}
pub fn dec_u8(self: *Self, n: u8) u8 {
    const result = n -% 1;
    const half_carry = (@as(i16, @intCast(n & 0xF)) - 1) < 0;

    self.set_flag(Flags.HalfCarry, half_carry);
    self.set_flag(Flags.Subtract, true);
    self.set_flag(Flags.Zero, (result == 0));
    return result;
}
pub fn add_hl(self: *Self, n: u16) void {
    const hl = self.get_hl();
    const result = hl +% n;
    const half_carry = (((hl & 0xFFF) + (n & 0xFFF)) & 0x1000) != 0;
    self.set_flag(Flags.Carry, hl > 0xFFFF - n);
    self.set_flag(Flags.HalfCarry, half_carry);
    self.set_flag(Flags.Subtract, false);
    self.set_hl(result);
}
pub fn ld_sp(self: *Self, n: u8) void {
    const signed_val = @as(i16, @intCast(n));
    const sp = self.stack_pointer;
    @setRuntimeSafety(false);
    const result = @as(i16, @bitCast(sp)) +% signed_val;

    self.set_flag(Flags.Carry, (result & 0xFF) < (sp & 0xFF));
    self.set_flag(Flags.HalfCarry, (result & 0xF) < (sp & 0xF));
    self.set_flag(Flags.Zero, false);
    self.set_flag(.Subtract, false);
    self.stack_pointer = @as(u16, @intCast(result));
}
pub fn ld_hl(self: *Self, n: u8) void {
    const signed_val = @as(i16, @intCast(n));
    const sp = self.stack_pointer;
    const result = @as(i16, @intCast(sp)) +% signed_val;

    self.set_flag(.Carry, (result & 0xFF) < (sp & 0xFF));
    self.set_flag(.HalfCarry, (result & 0xF) < (sp & 0xF));
    self.Zero(.Zero, false);
    self.set_flag(.Subtract, false);
    self.set_hl(result);
}

// Flag manipulation
pub fn set_flag(self: *Self, flag: Flags, value: bool) void {
    if (value) {
        self.registers[REG_F] |= @intFromEnum(flag);
    } else {
        self.registers[REG_F] &= ~@intFromEnum(flag);
    }
}

pub fn get_flag(self: *Self, flag: Flags) bool {
    return (self.registers[REG_F] & @intFromEnum(flag)) != 0;
}
pub fn daa(self: *Self) void {
    var a: u8 = self.registers[REG_A];
    var adjust: u8 = undefined;

    if (self.get_flag(.Carry)) {
        adjust = 0x60;
    }
    if (self.get_flag(.HalfCarry)) {
        adjust |= 0x06;
    }
    if (!self.get_flag(.Subtract)) {
        if (a & 0x0F > 0x09) {
            adjust |= 0x06;
        }
        if (a > 99) {
            adjust |= 0x60;
        }
        a +%= 1;
    } else {
        a +%= 1;
    }

    self.set_flag(.Carry, adjust >= 0x60);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Zero, a == 0);
    self.registers[REG_A] = a;
}
pub fn cpl(self: *Self) void {
    self.registers[REG_A] = ~self.registers[REG_A];
    self.set_flag(.HalfCarry, true);
    self.set_flag(.Subtract, true);
}
pub fn scf(self: *Self) void {
    self.set_flag(.Subtract, false);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Carry, true);
}
pub fn ccf(self: *Self) void {
    const bit: u8 = if (self.get_flag(.Carry))
        1
    else
        0;
    self.set_flag(.Subtract, false);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Carry, (bit ^ 1) == 1);
}

// 8-bit Rotate/Shift operations
pub fn rotate_left(self: *Self, n: u8, include_carry: bool, update_zero: bool) u8 {
    const bit7 = n >> 7;
    const result = if (include_carry)
        (n << 1) | @as(u8, @intFromBool(self.get_flag(.Carry)))
    else
        std.math.rotl(u8, n, 1);

    self.set_flag(.Carry, bit7 == 1);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, result == 0 and update_zero);
    return result;
}
pub fn rotate_right(self: *Self, n: u8, include_carry: bool, update_zero: bool) u8 {
    const bit1 = n & 1;
    const result = if (include_carry)
        (n >> 1) | (@as(u8, @intFromBool(self.get_flag(.Carry))) << 7)
    else
        std.math.rotr(u8, n, 1);

    self.set_flag(.Carry, bit1 == 1);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, result == 0 and update_zero);
    return result;
}
pub fn shift_left(self: *Self, n: u8) u8 {
    const result = n << 1;
    const bit7 = n >> 7;
    self.set_flag(.Carry, bit7 == 1);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, result == 0);
    return result;
}
pub fn shift_right(self: *Self, n: u8, keep_bit: bool) u8 {
    const result = if (keep_bit)
        (n >> 1) | (n & 0x80)
    else
        n >> 1;

    self.set_flag(.Carry, (n & 1) == 1);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, result == 0);
    return result;
}
pub fn swap(self: *Self, n: u8) u8 {
    const high = n >> 4;
    const low = n << 4;
    const result = low | high;
    self.set_flag(.Carry, false);
    self.set_flag(.HalfCarry, false);
    self.set_flag(.Subtract, false);
    self.set_flag(.Zero, result == 0);
    return result;
}
pub fn bit_flag(self: *Self, n: u8, bit: Bit) void {
    self.set_flag(.Zero, (@intFromEnum(bit) & ~n) != 0);
    self.set_flag(.HalfCarry, true);
    self.set_flag(.Subtract, false);
}
pub fn set(self: *Self, n: u8, bit: Bit) u8 {
    _ = self;
    return n | @intFromEnum(bit);
}
pub fn res(self: *Self, n: u8, bit: Bit) u8 {
    _ = self;
    return !(@intFromEnum(bit) & n);
}

// 16-bit register access helpers
pub fn get_af(self: *Self) u16 {
    return (@as(u16, self.registers[REG_A]) << 8) | @as(u16, self.registers[REG_F]);
}
pub fn set_af(self: *Self, value: u16) void {
    self.registers[REG_A] = @truncate((value & 0xFF00) >> 8);
    self.registers[REG_F] = @truncate(value & 0x00FF);
}
pub fn get_bc(self: *Self) u16 {
    return (@as(u16, self.registers[REG_B]) << 8) | @as(u16, self.registers[REG_C]);
}
pub fn set_bc(self: *Self, value: u16) void {
    self.registers[REG_B] = @truncate((value & 0xFF00) >> 8);
    self.registers[REG_C] = @truncate(value & 0x00FF);
}
pub fn get_de(self: *Self) u16 {
    return (@as(u16, self.registers[REG_D]) << 8) | @as(u16, self.registers[REG_E]);
}
pub fn set_de(self: *Self, value: u16) void {
    self.registers[REG_D] = @truncate((value & 0xFF00) >> 8);
    self.registers[REG_E] = @truncate(value & 0x00FF);
}
pub fn get_hl(self: *Self) u16 {
    return (@as(u16, self.registers[REG_H]) << 8) | @as(u16, self.registers[REG_L]);
}
pub fn set_hl(self: *Self, value: u16) void {
    self.registers[REG_H] = @truncate((value & 0xFF00) >> 8);
    self.registers[REG_L] = @truncate(value & 0x00FF);
}
pub fn hli(self: *Self) void {
    const new = self.get_hl() + 1;
    self.set_hl(new);
}
pub fn hld(self: *Self) void {
    const new = self.get_hl() - 1;
    self.set_hl(new);
}
// Memory access
pub fn read_byte(self: *Self, address: u16) u8 {
    return self.memory[address];
}

pub fn write_byte(self: *Self, address: u16, value: u8) void {
    self.memory[address] = value;
}

pub fn read_word(self: *Self, address: u16) u16 {
    const low: u8 = self.read_byte(address);
    const high: u8 = self.read_byte(address + 1);
    return (@as(u16, high) << 8) | low;
}

pub fn write_word(self: *Self, address: u16, value: u16) void {
    self.write_byte(address, @truncate(value & 0xFF));
    self.write_byte(address + 1, @truncate((value >> 8) & 0xFF));
}

// Stack operations
pub fn push(self: *Self, value: u16) void {
    self.stack_pointer -%= 2;
    self.write_word(self.stack_pointer, value);
}

pub fn pop(self: *Self) u16 {
    const value = self.read_word(self.stack_pointer);
    self.stack_pointer +%= 2;
    return value;
}

// Opcode fetch and execute
pub fn fetch_opcode(self: *Self) u8 {
    const opcode = self.memory[self.program_counter];
    self.program_counter +%= 1;
    return opcode;
}

pub fn fetch_byte(self: *Self) u8 {
    const byte = self.read_byte(self.program_counter);
    self.program_counter +%= 1;
    return byte;
}
pub fn fetch_word(self: *Self) u16 {
    const low = self.fetch_byte();
    const high = self.fetch_byte();
    return (@as(u16, high) << 8) | low;
}
pub fn execute_opcode(self: *Self) void {
    var cycles_this_op: usize = 4;
    switch (self.current_opcode) {
        0x01 => { // LD BC, d16
            const address = self.fetch_word();
            self.set_bc(address);
            cycles_this_op = 12;
        },
        0x11 => { // LD DE, d16
            const address = self.fetch_word();
            self.set_de(address);
            cycles_this_op = 12;
        },
        0x21 => { // LD HL, d16
            const address = self.fetch_word();
            self.set_hl(address);
            cycles_this_op = 12;
        },
        0x31 => { // LD SP, d16
            self.stack_pointer = self.fetch_word();
            cycles_this_op = 12;
        },
        0xF9 => { // Ld SP, HL
            self.stack_pointer = self.get_hl();
            cycles_this_op = 8;
        },
        // 8-bit loads
        0x7F => { // LD A, A
            self.registers[REG_A] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x78 => { // LD A, B
            self.registers[REG_A] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x79 => { // LD A, C
            self.registers[REG_A] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x7A => { // LD A, D
            self.registers[REG_A] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x7B => { // LD A, E
            self.registers[REG_A] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x7C => { // LD A, H
            self.registers[REG_A] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x7D => { // LD A, L
            self.registers[REG_A] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD B, r
        0x47 => { // LD B, A
            self.registers[REG_B] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x40 => { // LD B, B
            self.registers[REG_B] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x41 => { // LD B, C
            self.registers[REG_B] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x42 => { // LD B, D
            self.registers[REG_B] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x43 => { // LD B, E
            self.registers[REG_B] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x44 => { // LD B, H
            self.registers[REG_B] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x45 => { // LD B, L
            self.registers[REG_B] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD C, r
        0x4F => { // LD C, A
            self.registers[REG_C] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x48 => { // LD C, B
            self.registers[REG_C] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x49 => { // LD C, C
            self.registers[REG_C] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x4A => { // LD C, D
            self.registers[REG_C] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x4B => { // LD C, E
            self.registers[REG_C] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x4C => { // LD C, H
            self.registers[REG_C] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x4D => { // LD C, L
            self.registers[REG_C] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD D, r
        0x57 => { // LD D, A
            self.registers[REG_D] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x50 => { // LD D, B
            self.registers[REG_D] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x51 => { // LD D, C
            self.registers[REG_D] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x52 => { // LD D, D
            self.registers[REG_D] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x53 => { // LD D, E
            self.registers[REG_D] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x54 => { // LD D, H
            self.registers[REG_D] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x55 => { // LD D, L
            self.registers[REG_D] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD E, r
        0x5F => { // LD E, A
            self.registers[REG_E] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x58 => { // LD E, B
            self.registers[REG_E] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x59 => { // LD E, C
            self.registers[REG_E] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x5A => { // LD E, D
            self.registers[REG_E] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x5B => { // LD E, E
            self.registers[REG_E] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x5C => { // LD E, H
            self.registers[REG_E] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x5D => { // LD E, L
            self.registers[REG_E] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD H, r
        0x67 => { // LD H, A
            self.registers[REG_H] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x60 => { // LD H, B
            self.registers[REG_H] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x61 => { // LD H, C
            self.registers[REG_H] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x62 => { // LD H, D
            self.registers[REG_H] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x63 => { // LD H, E
            self.registers[REG_H] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x64 => { // LD H, H
            self.registers[REG_H] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x65 => { // LD H, L
            self.registers[REG_H] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD L, r
        0x6F => { // LD L, A
            self.registers[REG_L] = self.registers[REG_A];
            cycles_this_op = 4;
        },
        0x68 => { // LD L, B
            self.registers[REG_L] = self.registers[REG_B];
            cycles_this_op = 4;
        },
        0x69 => { // LD L, C
            self.registers[REG_L] = self.registers[REG_C];
            cycles_this_op = 4;
        },
        0x6A => { // LD L, D
            self.registers[REG_L] = self.registers[REG_D];
            cycles_this_op = 4;
        },
        0x6B => { // LD L, E
            self.registers[REG_L] = self.registers[REG_E];
            cycles_this_op = 4;
        },
        0x6C => { // LD L, H
            self.registers[REG_L] = self.registers[REG_H];
            cycles_this_op = 4;
        },
        0x6D => { // LD L, L
            self.registers[REG_L] = self.registers[REG_L];
            cycles_this_op = 4;
        },
        // LD r, n
        0x3E => { // LD A, n
            self.registers[REG_A] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x06 => { // LD B, n
            self.registers[REG_B] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x0E => { // LD C, n
            self.registers[REG_C] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x16 => { // LD D, n
            self.registers[REG_D] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x1E => { // LD E, n
            self.registers[REG_E] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x26 => { // LD H, n
            self.registers[REG_H] = self.fetch_byte();
            cycles_this_op = 8;
        },
        0x2E => { // LD L, n
            self.registers[REG_L] = self.fetch_byte();
            cycles_this_op = 8;
        },
        // LD r, (HL)
        0x7E => { // LD A, (HL)
            self.registers[REG_A] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x46 => { // LD B, (HL)
            self.registers[REG_B] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x4E => { // LD C, (HL)
            self.registers[REG_C] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x56 => { // LD D, (HL)
            self.registers[REG_D] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x5E => { // LD E, (HL)
            self.registers[REG_E] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x66 => { // LD H, (HL)
            self.registers[REG_H] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        0x6E => { // LD L, (HL)
            self.registers[REG_L] = self.read_byte(self.get_hl());
            cycles_this_op = 8;
        },
        // LD (HL), r
        0x77 => {
            self.set_hl(self.registers[REG_A]);
            cycles_this_op = 8;
        },
        0x70 => {
            self.set_hl(self.registers[REG_B]);
            cycles_this_op = 8;
        },
        0x71 => {
            self.set_hl(self.registers[REG_C]);
            cycles_this_op = 8;
        },
        0x72 => {
            self.set_hl(self.registers[REG_D]);
            cycles_this_op = 8;
        },
        0x73 => {
            self.set_hl(self.registers[REG_E]);
            cycles_this_op = 8;
        },
        0x74 => {
            self.set_hl(self.registers[REG_H]);
            cycles_this_op = 8;
        },
        0x75 => {
            self.set_hl(self.registers[REG_L]);
            cycles_this_op = 8;
        },
        // LD (HL), n
        0x36 => {
            self.set_hl(self.fetch_byte());
            cycles_this_op = 12;
        },
        // LD A, (BC)
        0x0A => {
            self.registers[REG_A] = self.read_byte(self.get_bc());
            cycles_this_op = 8;
        },
        // LD A, (DE)
        0x1A => {
            self.registers[REG_A] = self.read_byte(self.get_de());
            cycles_this_op = 8;
        },
        // LD A, (C)
        0xF2 => {
            const offset = 0xFF00 | @as(u16, self.registers[REG_C]);
            self.registers[REG_A] = self.read_byte(offset);
            cycles_this_op = 8;
        },
        // LD (C), A
        0xE2 => {
            const offset = 0xFF00 | @as(u16, self.registers[REG_C]);
            self.write_byte(offset, self.registers[REG_A]);
            cycles_this_op = 8;
        },
        // LD A, (n)
        0xF0 => {
            const offset = 0xFF00 | @as(u16, self.fetch_byte());
            self.registers[REG_A] = self.read_byte(offset);
            cycles_this_op = 12;
        },
        // LD (n), A
        0xE0 => {
            const offset = 0xFF00 | @as(u16, self.fetch_byte());
            self.write_byte(offset, self.registers[REG_A]);
            cycles_this_op = 12;
        },
        // LD A, (nn)
        0xFA => {
            const addr = self.fetch_word();
            self.registers[REG_A] = self.read_byte(addr);
            cycles_this_op = 16;
        },
        // LD (nn), A
        0xEA => {
            const addr = self.fetch_word();
            self.write_word(addr, self.registers[REG_A]);
            cycles_this_op = 16;
        },
        // LD A (HLI)
        0x2A => {
            self.registers[REG_A] = self.read_byte(self.get_hl());
            self.hli();
            cycles_this_op = 8;
        },
        // LD A (HLD)
        0x3A => {
            self.registers[REG_A] = self.read_byte(self.get_hl());
            self.hld();
            cycles_this_op = 8;
        },
        // LD (BC) A
        0x02 => {
            self.write_byte(self.get_bc(), self.registers[REG_A]);
            cycles_this_op = 8;
        },
        // LD (DE), A
        0x12 => {
            self.write_byte(self.get_de(), self.registers[REG_A]);
            cycles_this_op = 8;
        },
        // LD (HLI), A
        0x22 => {
            self.write_byte(self.get_hl(), self.registers[REG_A]);
            self.hli();
            cycles_this_op = 8;
        },
        // LD (HLD), A
        0x32 => {
            self.write_byte(self.get_hl(), self.registers[REG_A]);
            self.hld();
            cycles_this_op = 8;
        },
        // PUSH QQ
        0xC5 => {
            const addr = self.get_bc();
            self.push(addr);
            cycles_this_op = 16;
        },
        0xD5 => {
            const addr = self.get_de();
            self.push(addr);
            cycles_this_op = 16;
        },
        0xE5 => {
            const addr = self.get_hl();
            self.push(addr);
            cycles_this_op = 16;
        },
        0xF5 => { // PUSH AF
            const nn = self.get_af();
            self.push(nn);
            cycles_this_op = 14;
        },
        // POP QQ
        0xC1 => {
            const addr = self.pop();
            self.set_bc(addr);
            cycles_this_op = 12;
        },
        0xD1 => {
            const addr = self.pop();
            self.set_de(addr);
            cycles_this_op = 12;
        },
        0xE1 => {
            const addr = self.pop();
            self.set_hl(addr);
            cycles_this_op = 12;
        },
        0xF1 => {
            const qq = self.pop() & 0xFFF0;
            self.set_af(qq);
            cycles_this_op = 12;
        },
        0xF8 => { // LD HL, SP + e8
            const offset: i8 = @bitCast(self.fetch_byte()); // Fetch signed byte
            const sp: u16 = self.stack_pointer;

            // Perform addition in i32 to avoid truncation
            const result: u16 = @as(u16, @intCast(@as(i32, sp) + offset));

            self.set_hl(result);

            // Set flags
            self.set_flag(.Zero, false); // Z is always reset
            self.set_flag(.Subtract, false); // N is always reset
            self.set_flag(.HalfCarry, ((sp & 0xF) + (@as(u16, @intCast(offset)) & 0xF)) > 0xF);
            self.set_flag(.Carry, ((sp & 0xFF) + (@as(u16, @intCast(offset)) & 0xFF)) > 0xFF);

            cycles_this_op = 12;
        },
        0x08 => { // LD (nn), SP
            const addr: u16 = self.fetch_word();
            const sp: u16 = self.stack_pointer;

            self.write_byte(addr, @as(u8, @truncate(sp)));
            self.write_byte(addr, @as(u8, @truncate(sp >> 8)));

            cycles_this_op = 20;
        },
        // 8-bit Arithmetic
        // ADD A, r
        0x87 => {
            self.add_u8(self.registers[REG_A], false);
            cycles_this_op = 4;
        },
        0x80 => {
            self.add_u8(self.registers[REG_B], false);
            cycles_this_op = 4;
        },
        0x81 => {
            self.add_u8(self.registers[REG_C], false);
            cycles_this_op = 4;
        },
        0x82 => {
            self.add_u8(self.registers[REG_D], false);
            cycles_this_op = 4;
        },
        0x83 => {
            self.add_u8(self.registers[REG_E], false);
            cycles_this_op = 4;
        },
        0x84 => {
            self.add_u8(self.registers[REG_H], false);
            cycles_this_op = 4;
        },
        0x85 => {
            self.add_u8(self.registers[REG_L], false);
            cycles_this_op = 4;
        },
        // ADD A, n
        0xC6 => {
            const n = self.fetch_byte();
            self.add_u8(n, false);
            cycles_this_op = 8;
        },
        // ADD A, (HL)
        0x86 => {
            const hl = self.read_byte(self.get_hl());
            self.add_u8(hl, false);
            cycles_this_op = 8;
        },
        // ADC A, r
        0x8F => {
            self.add_u8(self.registers[REG_A], true);
            cycles_this_op = 4;
        },
        0x88 => {
            self.add_u8(self.registers[REG_B], true);
            cycles_this_op = 4;
        },
        0x89 => {
            self.add_u8(self.registers[REG_C], true);
            cycles_this_op = 4;
        },
        0x8A => {
            self.add_u8(self.registers[REG_D], true);
            cycles_this_op = 4;
        },
        0x8B => {
            self.add_u8(self.registers[REG_E], true);
            cycles_this_op = 4;
        },
        0x8C => {
            self.add_u8(self.registers[REG_H], true);
            cycles_this_op = 4;
        },
        0x8D => {
            self.add_u8(self.registers[REG_L], true);
            cycles_this_op = 4;
        },
        // ADC A, n
        0xCE => {
            const n = self.fetch_byte();
            self.add_u8(n, true);
            cycles_this_op = 8;
        },
        // ADC A, (HL)
        0x8E => {
            const hl = self.read_byte(self.get_hl());
            self.add_u8(hl, true);
            cycles_this_op = 8;
        },
        // SUB A, r
        0x97 => {
            self.sub_u8(self.registers[REG_A], false);
            cycles_this_op = 4;
        },
        0x90 => {
            self.sub_u8(self.registers[REG_B], false);
            cycles_this_op = 4;
        },
        0x91 => {
            self.sub_u8(self.registers[REG_C], false);
            cycles_this_op = 4;
        },
        0x92 => {
            self.sub_u8(self.registers[REG_D], false);
            cycles_this_op = 4;
        },
        0x93 => {
            self.sub_u8(self.registers[REG_E], false);
            cycles_this_op = 4;
        },
        0x94 => {
            self.sub_u8(self.registers[REG_H], false);
            cycles_this_op = 4;
        },
        0x95 => {
            self.sub_u8(self.registers[REG_L], false);
            cycles_this_op = 4;
        },
        // SUB A, n
        0xD6 => {
            self.sub_u8(self.fetch_byte(), false);
            cycles_this_op = 8;
        },
        // SUB A, (HL)
        0x96 => {
            const hl = self.read_byte(self.get_hl());
            self.sub_u8(hl, false);
            cycles_this_op = 8;
        },
        // SBC A, r
        0x9F => {
            self.sub_u8(self.registers[REG_A], true);
            cycles_this_op = 4;
        },
        0x98 => {
            self.sub_u8(self.registers[REG_B], true);
            cycles_this_op = 4;
        },
        0x99 => {
            self.sub_u8(self.registers[REG_C], true);
            cycles_this_op = 4;
        },
        0x9A => {
            self.sub_u8(self.registers[REG_D], true);
            cycles_this_op = 4;
        },
        0x9B => {
            self.sub_u8(self.registers[REG_E], true);
            cycles_this_op = 4;
        },
        0x9C => {
            self.sub_u8(self.registers[REG_H], true);
            cycles_this_op = 4;
        },
        0x9D => {
            self.sub_u8(self.registers[REG_L], true);
            cycles_this_op = 4;
        },
        // SBC A, n
        0xDE => {
            self.sub_u8(self.fetch_byte(), true);
            cycles_this_op = 8;
        },
        // SBC A, (HL)
        0x9E => {
            const hl = self.read_byte(self.get_hl());
            self.sub_u8(hl, true);
            cycles_this_op = 8;
        },
        // AND A, r
        0xA7 => {
            self.and_u8(self.registers[REG_A]);
            cycles_this_op = 4;
        },
        0xA0 => {
            self.and_u8(self.registers[REG_B]);
            cycles_this_op = 4;
        },
        0xA1 => {
            self.and_u8(self.registers[REG_C]);
            cycles_this_op = 4;
        },
        0xA2 => {
            self.and_u8(self.registers[REG_D]);
            cycles_this_op = 4;
        },
        0xA3 => {
            self.and_u8(self.registers[REG_E]);
            cycles_this_op = 4;
        },
        0xA4 => {
            self.and_u8(self.registers[REG_H]);
            cycles_this_op = 4;
        },
        0xA5 => {
            self.and_u8(self.registers[REG_L]);
            cycles_this_op = 4;
        },
        // AND A, (HL)
        0xA6 => {
            const hl = self.read_byte(self.get_hl());
            self.and_u8(hl);
            cycles_this_op = 8;
        },
        // AND A, n
        0xE6 => {
            self.and_u8(self.fetch_byte());
            cycles_this_op = 8;
        },
        // OR A, r
        0xB7 => {
            self.or_u8(self.registers[REG_A]);
            cycles_this_op = 4;
        },
        0xB0 => {
            self.or_u8(self.registers[REG_B]);
            cycles_this_op = 4;
        },
        0xB1 => {
            self.or_u8(self.registers[REG_C]);
            cycles_this_op = 4;
        },
        0xB2 => {
            self.or_u8(self.registers[REG_D]);
            cycles_this_op = 4;
        },
        0xB3 => {
            self.or_u8(self.registers[REG_E]);
            cycles_this_op = 4;
        },
        0xB4 => {
            self.or_u8(self.registers[REG_H]);
            cycles_this_op = 4;
        },
        0xB5 => {
            self.or_u8(self.registers[REG_L]);
            cycles_this_op = 4;
        },
        // OR A,  n
        0xF6 => {
            self.or_u8(self.fetch_byte());
            cycles_this_op = 8;
        },
        // OR A, (HL)
        0xB6 => {
            const hl = self.read_byte(self.get_hl());
            self.or_u8(hl);
            cycles_this_op = 8;
        },
        // XOR A, r
        0xAF => {
            self.xor_u8(self.registers[REG_A]);
            cycles_this_op = 4;
        },
        0xA8 => {
            self.xor_u8(self.registers[REG_B]);
            cycles_this_op = 4;
        },
        0xA9 => {
            self.xor_u8(self.registers[REG_C]);
            cycles_this_op = 4;
        },
        0xAA => {
            self.xor_u8(self.registers[REG_D]);
            cycles_this_op = 4;
        },
        0xAB => {
            self.xor_u8(self.registers[REG_E]);
            cycles_this_op = 4;
        },
        0xAC => {
            self.xor_u8(self.registers[REG_H]);
            cycles_this_op = 4;
        },
        0xAD => {
            self.xor_u8(self.registers[REG_L]);
            cycles_this_op = 4;
        },
        // XOR A, n
        0xEE => {
            self.xor_u8(self.fetch_byte());
            cycles_this_op = 8;
        },
        // XOR A, (HL)
        0xAE => {
            const hl = self.read_byte(self.get_hl());
            self.xor_u8(hl);
            cycles_this_op = 8;
        },
        // CP A, r
        0xBF => {
            self.cmp_u8(self.registers[REG_A]);
            cycles_this_op = 4;
        },
        0xB8 => {
            self.cmp_u8(self.registers[REG_B]);
            cycles_this_op = 4;
        },
        0xB9 => {
            self.cmp_u8(self.registers[REG_C]);
            cycles_this_op = 4;
        },
        0xBA => {
            self.cmp_u8(self.registers[REG_D]);
            cycles_this_op = 4;
        },
        0xBB => {
            self.cmp_u8(self.registers[REG_E]);
            cycles_this_op = 4;
        },
        0xBC => {
            self.cmp_u8(self.registers[REG_H]);
            cycles_this_op = 4;
        },
        0xBD => {
            self.cmp_u8(self.registers[REG_L]);
            cycles_this_op = 4;
        },
        // CP A, n
        0xFE => {
            self.cmp_u8(self.fetch_byte());
            cycles_this_op = 8;
        },
        // CP A, (HL)
        0xBE => {
            const hl = self.read_byte(self.get_hl());
            self.cmp_u8(hl);
            cycles_this_op = 8;
        },
        // INC r
        0x3C => {
            const r = self.registers[REG_A];
            self.registers[REG_A] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x04 => {
            const r = self.registers[REG_B];
            self.registers[REG_B] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x0C => {
            const r = self.registers[REG_C];
            self.registers[REG_C] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x14 => {
            const r = self.registers[REG_D];
            self.registers[REG_D] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x1C => {
            const r = self.registers[REG_E];
            self.registers[REG_E] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x24 => {
            const r = self.registers[REG_H];
            self.registers[REG_H] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        0x2C => {
            const r = self.registers[REG_L];
            self.registers[REG_L] = self.inc_u8(r);
            cycles_this_op = 4;
        },
        // INC (HL)
        0x34 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.inc_u8(n));
            cycles_this_op = 12;
        },
        // DEC r
        0x3D => {
            const r = self.registers[REG_A];
            self.registers[REG_A] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x05 => {
            const r = self.registers[REG_B];
            self.registers[REG_B] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x0D => {
            const r = self.registers[REG_C];
            self.registers[REG_C] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x15 => {
            const r = self.registers[REG_D];
            self.registers[REG_D] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x1D => {
            const r = self.registers[REG_E];
            self.registers[REG_E] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x25 => {
            const r = self.registers[REG_H];
            self.registers[REG_H] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        0x2D => {
            const r = self.registers[REG_L];
            self.registers[REG_L] = self.dec_u8(r);
            cycles_this_op = 4;
        },
        // DEC (HL)
        0x35 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.dec_u8(n));
            cycles_this_op = 12;
        },
        // ADD HL, rr
        0x09 => {
            const rr = self.get_bc();
            self.add_hl(rr);
            cycles_this_op = 8;
        },
        0x19 => {
            const rr = self.get_de();
            self.add_hl(rr);
            cycles_this_op = 8;
        },
        0x29 => {
            const rr = self.get_hl();
            self.add_hl(rr);
            cycles_this_op = 8;
        },
        0x39 => {
            self.add_hl(self.stack_pointer);
            cycles_this_op = 8;
        },
        // ADD SP, e
        0xE8 => {
            const e = self.fetch_byte();
            self.ld_sp(e);
            cycles_this_op = 16;
        },
        // INC ss (no flags changed)
        0x03 => {
            const rr = self.get_bc() +% 1;
            self.set_bc(rr);
            cycles_this_op = 8;
        },
        0x13 => {
            const rr = self.get_de() +% 1;
            self.set_de(rr);
            cycles_this_op = 8;
        },
        0x23 => {
            const rr = self.get_hl() +% 1;
            self.set_hl(rr);
            cycles_this_op = 8;
        },
        0x33 => {
            const rr = self.stack_pointer +% 1;
            self.stack_pointer = rr;
            cycles_this_op = 8;
        },
        // DEC ss (no flags changed here)
        0x0B => {
            const rr = self.get_bc() -% 1;
            self.set_bc(rr);
            cycles_this_op = 8;
        },
        0x1B => {
            const rr = self.get_de() -% 1;
            self.set_de(rr);
            cycles_this_op = 8;
        },
        0x2B => {
            const rr = self.get_hl() -% 1;
            self.set_hl(rr);
            cycles_this_op = 8;
        },
        0x3B => {
            const rr = self.stack_pointer -% 1;
            self.stack_pointer = rr;
            cycles_this_op = 8;
        },
        // Jump
        0xC3 => { // JP nn
            self.jump(self.fetch_word());
            cycles_this_op = 12;
        },
        // NOTE: POSSIBLY NOT CORRECT
        // get_flag() may be wrong
        0xC2 => { // JP NZ, nn
            const addr = self.fetch_word();
            self.jump_if(addr, .NotZero);
            cycles_this_op = if (!self.get_flag(.Zero)) 16 else 12;
        },
        0xCA => { // JP Z, nn
            const addr = self.fetch_word();
            self.jump_if(addr, .Zero);
            cycles_this_op = if (self.get_flag(.Zero)) 16 else 12;
        },
        0xD2 => { // JP NC, nn
            const addr = self.fetch_word();
            self.jump_if(addr, .NotCarry);
            cycles_this_op = if (!self.get_flag(.Carry)) 16 else 12;
        },
        0xDA => { // JP C, nn
            const addr = self.fetch_word();
            self.jump_if(addr, .Carry);
            cycles_this_op = if (self.get_flag(.Carry)) 16 else 12;
        },
        // JR e
        0x18 => {
            const e: i8 = @as(i8, @bitCast(self.fetch_byte()));
            self.jump_rel(e);
            cycles_this_op = 12;
        },
        // JR cc e,
        0x20 => {
            const e: i8 = @as(i8, @bitCast(self.fetch_byte()));
            self.jump_rel_if(e, .NotZero);
        },
        0x28 => {
            const e: i8 = @as(i8, @bitCast(self.fetch_byte()));
            self.jump_rel_if(e, .Zero);
        },
        0x30 => {
            const e: i8 = @as(i8, @bitCast(self.fetch_byte()));
            self.jump_rel_if(e, .NotCarry);
        },
        0x38 => {
            const e: i8 = @as(i8, @bitCast(self.fetch_byte()));
            self.jump_rel_if(e, .Carry);
        },
        // JP (HL)
        0xE9 => {
            self.jump(self.get_hl());
            cycles_this_op = 4;
        },
        // CALL
        0xCD => {
            const word = self.fetch_word();
            self.call(word);
            cycles_this_op = 24;
        },
        // RET
        0xC9 => {
            self.ret();
            cycles_this_op = 16;
        },
        // RET cc
        0xC0 => {
            self.ret_if(.NotZero);
            cycles_this_op = 20;
        },
        0xC8 => {
            self.ret_if(.Zero);
            cycles_this_op = 20;
        },
        0xD0 => {
            self.ret_if(.NotCarry);
            cycles_this_op = 20;
        },
        0xD8 => {
            self.ret_if(.Carry);
            cycles_this_op = 20;
        },
        // RETI (return from interrupt)
        0xD9 => {
            self.program_counter = self.pop();
            self.ime = true;
            cycles_this_op = 16;
        },
        // RST t
        0xC7 => {
            self.rst(.Rst1);
            cycles_this_op = 16;
        },
        0xCF => {
            self.rst(.Rst2);
            cycles_this_op = 16;
        },
        0xD7 => {
            self.rst(.Rst3);
            cycles_this_op = 16;
        },
        0xDF => {
            self.rst(.Rst4);
            cycles_this_op = 16;
        },
        0xE7 => {
            self.rst(.Rst5);
            cycles_this_op = 16;
        },
        0xEF => {
            self.rst(.Rst6);
            cycles_this_op = 16;
        },
        0xF7 => {
            self.rst(.Rst7);
            cycles_this_op = 16;
        },
        0xFF => {
            self.rst(.Rst8);
            cycles_this_op = 16;
        },
        // Rotates
        0x07 => {
            const a = self.registers[REG_A];
            self.registers[REG_A] = self.rotate_left(a, false, false);
            cycles_this_op = 4;
        },
        0x17 => {
            const a = self.registers[REG_A];
            self.registers[REG_A] = self.rotate_left(a, true, false);
            cycles_this_op = 4;
        },
        0x0F => {
            const a = self.registers[REG_A];
            self.registers[REG_A] = self.rotate_right(a, false, false);
            cycles_this_op = 4;
        },
        0x1F => {
            const a = self.registers[REG_A];
            self.registers[REG_A] = self.rotate_right(a, true, false);
            cycles_this_op = 4;
        },

        // Decimal Adjust Accumulator
        0x27 => {
            self.daa();
            cycles_this_op = 4;
        },
        // CPL
        0x2F => {
            self.cpl();
            cycles_this_op = 4;
        },
        // scf
        0x37 => {
            self.scf();
            cycles_this_op = 4;
        },
        // ccf
        0x3F => {
            self.ccf();
            cycles_this_op = 4;
        },
        // GBCPUMAN
        0xF3 => {
            self.ime = false;
            cycles_this_op = 4;
        },
        0xFB => {
            self.ime = true;
            cycles_this_op = 4;
        },
        // NOP
        0x00 => {
            cycles_this_op = 4;
        },
        // STOP
        0x10 => {
            cycles_this_op = 4;
        },
        // HALT
        0x76 => {
            self.halted = true;
            cycles_this_op = 4;
        },
        // Sup-ops
        0xCB => {
            try self.c_opcodes();
        },
        else => {
            self.unimplemented_opcode = self.current_opcode;
        },
    }
    self.debug();
    self.cycles += cycles_this_op;
}
pub fn c_opcodes(self: *Self) !void {
    const opcode = self.fetch_byte();
    const pc = self.program_counter;
    const regs = self.registers;
    var cycles_this_op: usize = undefined;

    _ = pc;

    switch (opcode) {
        // Rotate Left
        0x07 => {
            self.registers[REG_A] = self.rotate_left(regs[REG_A], false, true);
            cycles_this_op = 4;
        },
        0x00 => {
            self.registers[REG_B] = self.rotate_left(regs[REG_B], false, true);
            cycles_this_op = 4;
        },
        0x01 => {
            self.registers[REG_C] = self.rotate_left(regs[REG_C], false, true);
            cycles_this_op = 4;
        },
        0x02 => {
            self.registers[REG_D] = self.rotate_left(regs[REG_D], false, true);
            cycles_this_op = 4;
        },
        0x03 => {
            self.registers[REG_E] = self.rotate_left(regs[REG_E], false, true);
            cycles_this_op = 4;
        },
        0x04 => {
            self.registers[REG_H] = self.rotate_left(regs[REG_H], false, true);
            cycles_this_op = 4;
        },
        0x05 => {
            self.registers[REG_L] = self.rotate_left(regs[REG_L], false, true);
            cycles_this_op = 4;
        },
        0x06 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.rotate_left(n, false, true));
            cycles_this_op = 16;
        },
        0x17 => {
            self.registers[REG_A] = self.rotate_left(regs[REG_A], true, true);
            cycles_this_op = 8;
        },
        0x10 => {
            self.registers[REG_B] = self.rotate_left(regs[REG_B], true, true);
            cycles_this_op = 8;
        },
        0x11 => {
            self.registers[REG_C] = self.rotate_left(regs[REG_C], true, true);
            cycles_this_op = 8;
        },
        0x12 => {
            self.registers[REG_D] = self.rotate_left(regs[REG_D], true, true);
            cycles_this_op = 8;
        },
        0x13 => {
            self.registers[REG_E] = self.rotate_left(regs[REG_E], true, true);
            cycles_this_op = 8;
        },
        0x14 => {
            self.registers[REG_H] = self.rotate_left(regs[REG_H], true, true);
            cycles_this_op = 8;
        },
        0x15 => {
            self.registers[REG_L] = self.rotate_left(regs[REG_L], true, true);
            cycles_this_op = 8;
        },
        0x16 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.rotate_left(n, true, true));
            cycles_this_op = 16;
        },
        // Rotate right
        0x0F => {
            self.registers[REG_A] = self.rotate_right(regs[REG_A], false, true);
            cycles_this_op = 8;
        },
        0x08 => {
            self.registers[REG_B] = self.rotate_right(regs[REG_B], false, true);
            cycles_this_op = 8;
        },
        0x09 => {
            self.registers[REG_C] = self.rotate_right(regs[REG_C], false, true);
            cycles_this_op = 8;
        },
        0x0A => {
            self.registers[REG_D] = self.rotate_right(regs[REG_D], false, true);
            cycles_this_op = 8;
        },
        0x0B => {
            self.registers[REG_E] = self.rotate_right(regs[REG_E], false, true);
            cycles_this_op = 8;
        },
        0x0C => {
            self.registers[REG_H] = self.rotate_right(regs[REG_H], false, true);
            cycles_this_op = 8;
        },
        0x0D => {
            self.registers[REG_L] = self.rotate_right(regs[REG_L], false, true);
            cycles_this_op = 8;
        },
        0x0E => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.rotate_right(n, false, true));
            cycles_this_op = 16;
        },

        0x1F => {
            self.registers[REG_A] = self.rotate_right(regs[REG_A], true, true);
            cycles_this_op = 8;
        },
        0x18 => {
            self.registers[REG_B] = self.rotate_right(regs[REG_B], true, true);
            cycles_this_op = 8;
        },
        0x19 => {
            self.registers[REG_C] = self.rotate_right(regs[REG_C], true, true);
            cycles_this_op = 8;
        },
        0x1A => {
            self.registers[REG_D] = self.rotate_right(regs[REG_D], true, true);
            cycles_this_op = 8;
        },
        0x1B => {
            self.registers[REG_E] = self.rotate_right(regs[REG_E], true, true);
            cycles_this_op = 8;
        },
        0x1C => {
            self.registers[REG_H] = self.rotate_right(regs[REG_H], true, true);
            cycles_this_op = 8;
        },
        0x1D => {
            self.registers[REG_L] = self.rotate_right(regs[REG_L], true, true);
            cycles_this_op = 8;
        },
        0x1E => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.rotate_right(n, true, true));
            cycles_this_op = 16;
        },
        // Shift left
        0x27 => {
            self.registers[REG_A] = self.shift_left(regs[REG_A]);
            cycles_this_op = 8;
        },
        0x20 => {
            self.registers[REG_B] = self.shift_left(regs[REG_B]);
            cycles_this_op = 8;
        },
        0x21 => {
            self.registers[REG_C] = self.shift_left(regs[REG_C]);
            cycles_this_op = 8;
        },
        0x22 => {
            self.registers[REG_D] = self.shift_left(regs[REG_D]);
            cycles_this_op = 8;
        },
        0x23 => {
            self.registers[REG_E] = self.shift_left(regs[REG_E]);
            cycles_this_op = 8;
        },
        0x24 => {
            self.registers[REG_H] = self.shift_left(regs[REG_H]);
            cycles_this_op = 8;
        },
        0x25 => {
            self.registers[REG_L] = self.shift_left(regs[REG_L]);
            cycles_this_op = 8;
        },
        0x26 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.shift_left(n));
            cycles_this_op = 16;
        },
        // Shift right
        0x2F => {
            self.registers[REG_A] = self.shift_right(regs[REG_A], true);
            cycles_this_op = 8;
        },
        0x28 => {
            self.registers[REG_B] = self.shift_right(regs[REG_B], true);
            cycles_this_op = 8;
        },
        0x29 => {
            self.registers[REG_C] = self.shift_right(regs[REG_C], true);
            cycles_this_op = 8;
        },
        0x2A => {
            self.registers[REG_D] = self.shift_right(regs[REG_D], true);
            cycles_this_op = 8;
        },
        0x2B => {
            self.registers[REG_E] = self.shift_right(regs[REG_E], true);
            cycles_this_op = 8;
        },
        0x2C => {
            self.registers[REG_H] = self.shift_right(regs[REG_H], true);
            cycles_this_op = 8;
        },
        0x2D => {
            self.registers[REG_L] = self.shift_right(regs[REG_L], true);
            cycles_this_op = 8;
        },
        0x2E => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.shift_right(n, true));
            cycles_this_op = 16;
        },

        0x3F => {
            self.registers[REG_A] = self.shift_right(regs[REG_A], false);
            cycles_this_op = 8;
        },
        0x38 => {
            self.registers[REG_B] = self.shift_right(regs[REG_B], false);
            cycles_this_op = 8;
        },
        0x39 => {
            self.registers[REG_C] = self.shift_right(regs[REG_C], false);
            cycles_this_op = 8;
        },
        0x3A => {
            self.registers[REG_D] = self.shift_right(regs[REG_D], false);
            cycles_this_op = 8;
        },
        0x3B => {
            self.registers[REG_E] = self.shift_right(regs[REG_E], false);
            cycles_this_op = 8;
        },
        0x3C => {
            self.registers[REG_H] = self.shift_right(regs[REG_H], false);
            cycles_this_op = 8;
        },
        0x3D => {
            self.registers[REG_L] = self.shift_right(regs[REG_L], false);
            cycles_this_op = 8;
        },
        0x3E => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.shift_right(n, false));
            cycles_this_op = 16;
        },
        // Swap
        0x37 => {
            self.registers[REG_A] = self.swap(regs[REG_A]);
            cycles_this_op = 8;
        },
        0x30 => {
            self.registers[REG_B] = self.swap(regs[REG_B]);
            cycles_this_op = 8;
        },
        0x31 => {
            self.registers[REG_C] = self.swap(regs[REG_C]);
            cycles_this_op = 8;
        },
        0x32 => {
            self.registers[REG_D] = self.swap(regs[REG_D]);
            cycles_this_op = 8;
        },
        0x33 => {
            self.registers[REG_E] = self.swap(regs[REG_E]);
            cycles_this_op = 8;
        },
        0x34 => {
            self.registers[REG_H] = self.swap(regs[REG_H]);
            cycles_this_op = 8;
        },
        0x35 => {
            self.registers[REG_L] = self.swap(regs[REG_L]);
            cycles_this_op = 8;
        },
        0x36 => {
            const n = self.read_byte(self.get_hl());
            self.write_byte(self.get_hl(), self.swap(n));
            cycles_this_op = 16;
        },
        // Bit
        0x47 => {
            self.bit_flag(self.registers[REG_A], .Bit0);
            cycles_this_op = 8;
        },
        0x4F => {
            self.bit_flag(self.registers[REG_A], .Bit1);
            cycles_this_op = 8;
        },
        0x57 => {
            self.bit_flag(self.registers[REG_A], .Bit2);
            cycles_this_op = 8;
        },
        0x5F => {
            self.bit_flag(self.registers[REG_A], .Bit2);
            cycles_this_op = 8;
        },
        0x67 => {
            self.bit_flag(self.registers[REG_A], .Bit4);
            cycles_this_op = 8;
        },
        0x6F => {
            self.bit_flag(self.registers[REG_A], .Bit5);
            cycles_this_op = 8;
        },
        0x77 => {
            self.bit_flag(self.registers[REG_A], .Bit6);
            cycles_this_op = 8;
        },
        0x7F => {
            self.bit_flag(self.registers[REG_A], .Bit7);
            cycles_this_op = 8;
        },
        0x40 => {
            self.bit_flag(self.registers[REG_B], .Bit0);
            cycles_this_op = 8;
        },
        0x48 => {
            self.bit_flag(self.registers[REG_B], .Bit1);
            cycles_this_op = 8;
        },
        0x50 => {
            self.bit_flag(self.registers[REG_B], .Bit2);
            cycles_this_op = 8;
        },
        0x58 => {
            self.bit_flag(self.registers[REG_B], .Bit3);
            cycles_this_op = 8;
        },
        0x60 => {
            self.bit_flag(self.registers[REG_B], .Bit4);
            cycles_this_op = 8;
        },
        0x68 => {
            self.bit_flag(self.registers[REG_B], .Bit5);
            cycles_this_op = 8;
        },
        0x70 => {
            self.bit_flag(self.registers[REG_B], .Bit6);
            cycles_this_op = 8;
        },
        0x78 => {
            self.bit_flag(self.registers[REG_B], .Bit7);
            cycles_this_op = 8;
        },
        0x41 => {
            self.bit_flag(self.registers[REG_C], .Bit0);
            cycles_this_op = 8;
        },
        0x49 => {
            self.bit_flag(self.registers[REG_C], .Bit1);
            cycles_this_op = 8;
        },
        0x51 => {
            self.bit_flag(self.registers[REG_C], .Bit2);
            cycles_this_op = 8;
        },
        0x59 => {
            self.bit_flag(self.registers[REG_C], .Bit3);
            cycles_this_op = 8;
        },
        0x61 => {
            self.bit_flag(self.registers[REG_C], .Bit4);
            cycles_this_op = 8;
        },
        0x69 => {
            self.bit_flag(self.registers[REG_C], .Bit5);
            cycles_this_op = 8;
        },
        0x71 => {
            self.bit_flag(self.registers[REG_C], .Bit6);
            cycles_this_op = 8;
        },
        0x79 => {
            self.bit_flag(self.registers[REG_C], .Bit7);
            cycles_this_op = 8;
        },
        0x42 => {
            self.bit_flag(self.registers[REG_D], .Bit0);
            cycles_this_op = 8;
        },
        0x4A => {
            self.bit_flag(self.registers[REG_D], .Bit1);
            cycles_this_op = 8;
        },
        0x52 => {
            self.bit_flag(self.registers[REG_D], .Bit2);
            cycles_this_op = 8;
        },
        0x5A => {
            self.bit_flag(self.registers[REG_D], .Bit3);
            cycles_this_op = 8;
        },
        0x62 => {
            self.bit_flag(self.registers[REG_D], .Bit4);
            cycles_this_op = 8;
        },
        0x6A => {
            self.bit_flag(self.registers[REG_D], .Bit5);
            cycles_this_op = 8;
        },
        0x72 => {
            self.bit_flag(self.registers[REG_D], .Bit6);
            cycles_this_op = 8;
        },
        0x7A => {
            self.bit_flag(self.registers[REG_D], .Bit7);
            cycles_this_op = 8;
        },

        0x43 => {
            self.bit_flag(self.registers[REG_E], .Bit0);
            cycles_this_op = 8;
        },
        0x4B => {
            self.bit_flag(self.registers[REG_E], .Bit1);
            cycles_this_op = 8;
        },
        0x53 => {
            self.bit_flag(self.registers[REG_E], .Bit2);
            cycles_this_op = 8;
        },
        0x5B => {
            self.bit_flag(self.registers[REG_E], .Bit3);
            cycles_this_op = 8;
        },
        0x63 => {
            self.bit_flag(self.registers[REG_E], .Bit4);
            cycles_this_op = 8;
        },
        0x6B => {
            self.bit_flag(self.registers[REG_E], .Bit5);
            cycles_this_op = 8;
        },
        0x73 => {
            self.bit_flag(self.registers[REG_E], .Bit6);
            cycles_this_op = 8;
        },
        0x7B => {
            self.bit_flag(self.registers[REG_E], .Bit7);
            cycles_this_op = 8;
        },

        0x44 => {
            self.bit_flag(self.registers[REG_H], .Bit0);
            cycles_this_op = 8;
        },
        0x4C => {
            self.bit_flag(self.registers[REG_H], .Bit1);
            cycles_this_op = 8;
        },
        0x54 => {
            self.bit_flag(self.registers[REG_H], .Bit2);
            cycles_this_op = 8;
        },
        0x5C => {
            self.bit_flag(self.registers[REG_H], .Bit3);
            cycles_this_op = 8;
        },
        0x64 => {
            self.bit_flag(self.registers[REG_H], .Bit3);
            cycles_this_op = 8;
        },
        0x6C => {
            self.bit_flag(self.registers[REG_H], .Bit4);
            cycles_this_op = 8;
        },
        0x74 => {
            self.bit_flag(self.registers[REG_H], .Bit5);
            cycles_this_op = 8;
        },
        0x7C => {
            self.bit_flag(self.registers[REG_H], .Bit6);
            cycles_this_op = 8;
        },

        0x45 => {
            self.bit_flag(self.registers[REG_L], .Bit0);
            cycles_this_op = 8;
        },
        0x4D => {
            self.bit_flag(self.registers[REG_L], .Bit1);
            cycles_this_op = 8;
        },
        0x55 => {
            self.bit_flag(self.registers[REG_L], .Bit2);
            cycles_this_op = 8;
        },
        0x5D => {
            self.bit_flag(self.registers[REG_L], .Bit3);
            cycles_this_op = 8;
        },
        0x65 => {
            self.bit_flag(self.registers[REG_L], .Bit4);
            cycles_this_op = 8;
        },
        0x6D => {
            self.bit_flag(self.registers[REG_L], .Bit5);
            cycles_this_op = 8;
        },
        0x75 => {
            self.bit_flag(self.registers[REG_L], .Bit6);
            cycles_this_op = 8;
        },
        0x7D => {
            self.bit_flag(self.registers[REG_L], .Bit7);
            cycles_this_op = 8;
        },

        0x46 => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit0);
            cycles_this_op = 12;
        },
        0x4E => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit1);
            cycles_this_op = 12;
        },
        0x56 => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit2);
            cycles_this_op = 12;
        },
        0x5E => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit3);
            cycles_this_op = 12;
        },
        0x66 => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit4);
            cycles_this_op = 12;
        },
        0x6E => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit5);
            cycles_this_op = 12;
        },
        0x76 => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit6);
            cycles_this_op = 12;
        },
        0x7E => {
            const n = self.read_byte(self.get_hl());
            self.bit_flag(n, .Bit7);
            cycles_this_op = 12;
        },
        // Set
        0xC7 => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit0);
            cycles_this_op = 8;
        },
        0xCF => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit1);
            cycles_this_op = 8;
        },
        0xD7 => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit2);
            cycles_this_op = 8;
        },
        0xDF => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit3);
            cycles_this_op = 8;
        },
        0xE7 => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit4);
            cycles_this_op = 8;
        },
        0xEF => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit5);
            cycles_this_op = 8;
        },
        0xF7 => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit6);
            cycles_this_op = 8;
        },
        0xFF => {
            self.registers[REG_A] = self.set(regs[REG_A], .Bit7);
            cycles_this_op = 8;
        },

	0xC0 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit0);
            cycles_this_op = 8;
	},
	0xC8 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit1);
            cycles_this_op = 8;
	},
	0xD0 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit2);
            cycles_this_op = 8;
	},
	0xD8 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit3);
            cycles_this_op = 8;
	},
	0xE0 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit4);
            cycles_this_op = 8;
	},
	0xE8 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit5);
            cycles_this_op = 8;
	},
	0xF0 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit6);
            cycles_this_op = 8;
	},
	0xF8 => {
            self.registers[REG_B] = self.set(regs[REG_B], .Bit7);
            cycles_this_op = 8;
	},

	0xC1 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit0);
            cycles_this_op = 8;
	},
	0xC9 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit1);
            cycles_this_op = 8;
	},
	0xD1 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit2);
            cycles_this_op = 8;
	},
	0xD9 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit3);
            cycles_this_op = 8;
	},
	0xE1 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit4);
            cycles_this_op = 8;
	},
	0xE9 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit5);
            cycles_this_op = 8;
	},
	0xF1 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit6);
            cycles_this_op = 8;
	},
	0xF9 => {
            self.registers[REG_C] = self.set(regs[REG_C], .Bit7);
            cycles_this_op = 8;
	},

	0xC2 => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit0);
            cycles_this_op = 8;
	},
	0xCA => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit1);
            cycles_this_op = 8;
	},
	0xD2 => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit2);
            cycles_this_op = 8;
	},
	0xDA => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit3);
            cycles_this_op = 8;
	},
	0xE2 => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit4);
            cycles_this_op = 8;
	},
	0xEA => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit5);
            cycles_this_op = 8;
	},
	0xF2 => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit6);
            cycles_this_op = 8;
	},
	0xFA => {
            self.registers[REG_D] = self.set(regs[REG_D], .Bit7);
            cycles_this_op = 8;
	},

	0xC3 => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit0);
            cycles_this_op = 8;
	},
	0xCB => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit1);
            cycles_this_op = 8;
	},
	0xD3 => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit2);
            cycles_this_op = 8;
	},
	0xDB => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit3);
            cycles_this_op = 8;
	},
	0xE3 => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit4);
            cycles_this_op = 8;
	},
	0xEB => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit5);
            cycles_this_op = 8;
	},
	0xF3 => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit6);
            cycles_this_op = 8;
	},
	0xFB => {
            self.registers[REG_E] = self.set(regs[REG_E], .Bit7);
            cycles_this_op = 8;
	},
        else => {
            self.unimplemented_opcode = opcode;
        },
    }
}
pub fn cycle(self: *Self) void {
    if (self.halted) {
        self.cycles += 4;
        return;
    }
    if (self.program_counter > 0xFFFF)
        @panic("OPcode out of range! Your program has an error!");
    self.current_opcode = self.fetch_opcode();
    self.execute_opcode();
}

pub fn loadROM(self: *Self, filename: []const u8) !void {
    var inputFile = try std.fs.cwd().openFile(filename, .{});

    defer inputFile.close();

    println("Loading ROM!");
    const size = try inputFile.getEndPos();
    print("ROM File Size {}\n", .{size});
    var reader = inputFile.reader();

    if (size > self.memory.len) {
        return error.InvalidROMSize;
    }
    for (0..size) |i| {
        self.memory[i] = try reader.readByte();
    }
    println("Loading ROM Succeded!");
}

pub fn init(self: *Self) void {
    println("Initializing CPU!");

    self.current_opcode = 0x00;
    self.unimplemented_opcode = 0x76;
    self.stack_pointer = 0xFFFE;
    self.program_counter = 0x100;
    self.cycles = 0x0;

    // Clear memory
    for (&self.memory) |*m| {
        m.* = 0x00;
    }
    // Clear registers
    for (&self.registers) |*r| {
        r.* = 0x00;
    }
    // Clear graphics
    for (&self.graphics) |*g| {
        g.* = 0x00;
    }

    self.write_byte(0xFF40, 0x91);
    self.write_byte(0xFF47, 0xE4);

    self.registers[REG_A] = 0x01;
    self.registers[REG_B] = 0x00;
    self.registers[REG_C] = 0x13;
    self.registers[REG_D] = 0x00;
    self.registers[REG_E] = 0xD8;
    self.registers[REG_H] = 0x01;
    self.registers[REG_L] = 0x4D;
    self.registers[REG_F] = 0xB0;
}
