// gba_eeprom_model.sv - a behavioural GBA serial EEPROM for the testbenches.
//
// Not a testbench: no SOURCES line, no pass line. Named in the SOURCES line of
// whatever instantiates it.
//
// It decides what to do from the protocol alone, the way a chip does: it
// watches WR# rising with CS1# low and takes AD0, and drives AD0 while RD# is
// low with CS1# low. It knows nothing about the module driving it, so a wrong
// bit order, a wrong bit count or a wrong address all show up as wrong data
// rather than as agreement by construction.
//
// THE SAFETY ASSERTION. A read request is 1 1, an address, then 0. A write is
// 1 0, an address, then 64 bits of data. One bit separates reading somebody's
// save from overwriting it, so this model kills the simulation the instant it
// sees a 1 0 prefix. Nothing in this project may emit one.
`default_nettype none

module gba_eeprom_model (
    input  wire        cart_mode,
    // 6 for a 512 byte chip, 14 for 8 KiB. An input rather than a parameter so
    // one testbench can be both chips in turn.
    input  wire [3:0]  chip_addr_bits,
    input  wire [7:4]  bank0,       // {?, WR#, RD#, CS1#}
    input  wire        pin30,       // CS2#
    inout  tri  [7:0]  bank3,       // AD low byte, AD0 is the serial line
    input  wire        bank3_dir,

    // The block the last request asked for, and how many requests there were.
    output reg  [13:0] req_block,
    output reg  [31:0] req_count,
    output reg  [31:0] bit_writes,
    output reg  [31:0] bit_reads
);

// The chip's contents: a function of the block, so every block differs from
// its neighbours and a stuck or off-by-one address cannot pass.
function [63:0] block_content(input [13:0] b);
    integer k;
    reg [63:0] v;
begin
    v = 64'd0;
    for (k = 0; k < 8; k = k + 1)
        v = {v[55:0], ({b[3:0], b[7:4]} ^ b[13:8] ^ k[7:0]) ^ 8'hC3};
    block_content = v;
end
endfunction

reg [5:0]  in_idx  = 6'd0;
reg [1:0]  cmd     = 2'b00;
reg [14:0] payload_sr = 15'd0;
reg        reading = 1'b0;
reg [6:0]  out_idx = 7'd0;
reg [63:0] out_sr  = 64'd0;

wire wr_n  = bank0[6];
wire rd_n  = bank0[5];
wire cs1_n = bank0[4];

wire selected = cart_mode && (cs1_n === 1'b0) && (pin30 === 1'b1);

// Driven only while the host has released AD and RD# is low. Bit 4 onwards is
// the data; the first four are the chip turning round and read as zero.
wire out_bit = (out_idx < 7'd4) ? 1'b0 : out_sr[63];
wire drive   = reading && selected && (rd_n === 1'b0) && (bank3_dir === 1'b0);
assign bank3 = drive ? {7'b0000000, out_bit} : 8'hzz;

// One request bit, taken on the WR# rising edge, which is when a chip latches.
always @(posedge bank0[6]) begin
    #1;
    if (selected) begin
        bit_writes = bit_writes + 32'd1;
        // A write while the chip is returning data aborts the read. The bit
        // becomes the first of a new command, which is how a flush drags a
        // chip that was left mid-command back to a known state.
        if (reading) begin
            reading = 1'b0;
            out_idx = 7'd0;
            in_idx  = 6'd0;
        end

        // Hunting for a start bit. A zero here is not consumed: the chip has
        // not been addressed and stays where it is. That is what makes a run
        // of zeros a reliable flush, because it leaves a chip at rest exactly
        // where it was and drags a chip mid-command back to the same place,
        // rather than leaving the result depending on how many zeros were
        // sent.
        if (in_idx == 6'd0) begin
            if (bank3[0] === 1'b1) begin
                cmd[1] = 1'b1;
                in_idx = 6'd1;
            end
        end else if (in_idx == 6'd1) begin
            cmd[0] = bank3[0];
            if ({cmd[1], bank3[0]} == 2'b10)
                $fatal(1, "EEPROM WRITE COMMAND emitted (1 0). This module must never write.");
            payload_sr = 15'd0;
            in_idx = 6'd2;
        end else begin
            // Keep the complete host payload. The narrow cartridge result is
            // equivalent to decoding the first six address bits from a wide
            // request, not to stopping the transfer after six bits. Modelling
            // that observed input/output behaviour is enough here; the chip's
            // internal state machine is not known.
            if (in_idx < 6'd17) begin
                payload_sr = {payload_sr[13:0], bank3[0]};
                in_idx     = in_idx + 6'd1;
            end
        end
    end
end

// One returned bit per RD# pulse. Advanced when RD# rises, so the value is
// stable for the whole window the host samples in.
//
// Both wrong widths answer. A short request to a wide chip returns a wrong
// block, as Minish Cap showed. A wide request to a narrow chip uses the first
// six address bits, as Super Mario Advance showed. The latter makes wide
// blocks 0 through 63 all alias narrow block zero.
//
// No mechanism is known for the particular wide-chip block returned by an
// under-run, and nothing may depend on the +2 below. It only preserves the
// observed fact that the request answers with a block other than the one
// requested.
always @(posedge bank0[5]) begin
    #1;
    if (selected && !reading && (in_idx == 6'd9 || in_idx == 6'd17)) begin
        if (payload_sr[0] !== 1'b0)
            $fatal(1, "EEPROM request terminator was %b, expected 0", payload_sr[0]);

        if (chip_addr_bits == 4'd6)
            req_block = (in_idx == 6'd17) ? {8'd0, payload_sr[14:9]}
                                          : {8'd0, payload_sr[6:1]};
        else
            req_block = (in_idx == 6'd17) ? payload_sr[14:1]
                                          : ({8'd0, payload_sr[6:1]} + 14'd2);

        req_count = req_count + 32'd1;
        out_sr    = block_content(req_block);
        out_idx   = 7'd0;
        reading   = 1'b1;
        in_idx    = 6'd0;
    end else if (selected && !reading && in_idx != 6'd0) begin
        // An incomplete or overlong command is abandoned when the host turns
        // around. A later zero flush then begins from the idle state.
        in_idx = 6'd0;
    end
    if (reading && selected) begin
        bit_reads = bit_reads + 32'd1;
        if (out_idx >= 7'd4) out_sr = {out_sr[62:0], 1'b0};
        if (out_idx + 7'd1 >= 7'd68) begin
            reading = 1'b0;
            out_idx = 7'd0;
        end else begin
            out_idx = out_idx + 7'd1;
        end
    end
end

initial begin
    req_block  = 14'd0;
    req_count  = 32'd0;
    bit_writes = 32'd0;
    bit_reads  = 32'd0;
end

endmodule

`default_nettype wire
