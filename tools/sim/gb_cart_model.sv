//
// gb_cart_model.sv - a Game Boy cartridge that talks back
//
// Connects to the gb_cart_bus engine interface, not to pins, so a bus bug and
// a pin-mux bug stay separable.
//
// Decodes the way a real cartridge does, from docs/HARDWARE-NOTES.md section 5:
//
//   0x0000-0x7FFF  ROM. Selected by address alone. /CS is NOT involved
//   0xA000-0xBFFF  RAM. Requires /CS low AND the RAM gate to be open
//   a write below 0x8000 is a mapper register write, not an error
//
// RAM_NEEDS_ENABLE models the gate: a real cartridge answers in the RAM window
// only after 0x0A has been written to 0x0000-0x1FFF, and reads open bus until
// then. It defaults on, because a model that answers without it makes a reader
// that forgets to enable the RAM pass its own test - which is the exact shape
// of the blank-file trap in docs/GB-SAVE-PLAN.md, an 8 KB file of 0xFF that
// looks like a successful backup. tb_gb_cart_bus turns it off deliberately;
// that testbench is about the /CS decode and the strobe timing, not about
// mapper semantics.
//
// CONTENTION_FATAL makes it stop the run if it would drive the data pins while
// the engine is also driving them.
//
`default_nettype none

module gb_cart_model #(
    parameter integer ROM_BYTES        = 32768,
    parameter integer RAM_BYTES        = 8192,
    parameter         RAM_NEEDS_ENABLE = 1,
    parameter         CONTENTION_FATAL = 1,
    parameter         PRESENT          = 1     // 0 = empty slot, pins float high
) (
    input  wire [15:0] e_ad_out,
    input  wire        e_ad_oe,
    input  wire [7:0]  e_hi_out,
    input  wire        e_hi_oe,
    input  wire [3:0]  e_ctl_out,     // {PHI, WR_n, RD_n, CS_n}
    input  wire        e_p30_out,
    input  wire        e_p30_oe,
    output wire [7:0]  e_hi_in,

    output reg         contention_seen,
    output reg  [15:0] last_write_addr,
    output reg  [7:0]  last_write_data,
    output reg  [31:0] rom_read_count,
    output reg         cs_during_rom_read,

    // Whether the RAM gate is open right now, and whether a byte was ever
    // written into the RAM window. A save backup must leave the first low and
    // the second zero: it opens the gate, reads, and closes it again, and it
    // never writes a byte of save data back.
    output reg         ram_enabled,
    output reg  [31:0] ram_write_count,
    // High once a read landed in the RAM window while the gate was shut. Not
    // an error - the presence probe does exactly this on purpose - but a
    // reader that did it for the whole pass would be filing open bus as a
    // save, so a test can tell the two apart.
    output reg         read_while_disabled
);

reg [7:0] rom [0:ROM_BYTES-1];
reg [7:0] ram [0:RAM_BYTES-1];

wire phi  = e_ctl_out[3];
wire wr_n = e_ctl_out[2];
wire rd_n = e_ctl_out[1];
wire cs_n = e_ctl_out[0];

wire in_rom = (e_ad_out < 16'h8000);
wire in_window = (e_ad_out[15:13] == 3'b101) && !cs_n;
wire in_ram = in_window && (ram_enabled || !RAM_NEEDS_ENABLE);

// The cartridge drives the data bus only while /RD is low and the access
// targets something it answers to. A held reset silences it.
wire driving = PRESENT && e_p30_oe && e_p30_out && !rd_n && (in_rom || in_ram);

wire [7:0] rom_byte = rom[e_ad_out[$clog2(ROM_BYTES)-1:0]];
wire [7:0] ram_byte = ram[e_ad_out[$clog2(RAM_BYTES)-1:0]];

// An empty slot reads back as all ones, which is what the identifier uses to
// tell "nothing there" from "something answered".
assign e_hi_in = driving ? (in_rom ? rom_byte : ram_byte) : 8'hFF;

initial begin
    contention_seen    = 1'b0;
    last_write_addr    = 16'h0;
    last_write_data    = 8'h0;
    rom_read_count      = 32'd0;
    cs_during_rom_read  = 1'b0;
    ram_enabled         = 1'b0;
    ram_write_count     = 32'd0;
    read_while_disabled = 1'b0;
end

always @(*) begin
    if (driving && e_hi_oe) begin
        contention_seen = 1'b1;
        if (CONTENTION_FATAL)
            $fatal(1, "gb_cart_model: contention, both sides driving D0-D7 at addr %04x",
                   e_ad_out);
    end
end

// A ROM read with /CS low would mean the bus is asserting a signal a Game Boy
// only asserts for RAM. Recorded rather than fatal: it is wrong, not unsafe.
always @(negedge rd_n) begin
    if (PRESENT && in_rom) begin
        rom_read_count = rom_read_count + 1;
        if (!cs_n) cs_during_rom_read = 1'b1;
    end
    if (PRESENT && in_window && !ram_enabled) read_while_disabled = 1'b1;
end

// A cartridge latches write data on the rising edge of /WR.
always @(posedge wr_n) begin
    if (PRESENT && e_hi_oe) begin
        last_write_addr = e_ad_out;
        last_write_data = e_hi_out;

        // The gate. Every mapper decodes the low nibble and nothing else, so
        // 0x0A and 0x1A both open it and 0x00 and 0x07 both shut it.
        if (e_ad_out < 16'h2000)
            ram_enabled = (e_hi_out[3:0] == 4'hA);

        if (e_ad_out >= 16'hA000 && e_ad_out < 16'hC000 && !cs_n) begin
            ram_write_count = ram_write_count + 1;
            if (ram_enabled || !RAM_NEEDS_ENABLE)
                ram[e_ad_out[$clog2(RAM_BYTES)-1:0]] = e_hi_out;
        end
    end
end

endmodule

`default_nettype wire
