// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_crc32.sv - an identity for the image, for cartridges that describe
//                 nothing about themselves
//
// dump_checksum.sv asks the cartridge what its contents should sum to. That
// works on Game Boy because a GB cartridge stores a 16-bit sum of itself at
// 0x14E. A GBA cartridge stores no such thing: its only checksum, at 0xBD,
// covers the 29 header bytes 0xA0-0xBC and nothing else, and cart_identify_gba
// already checks that. So the test that caught the floating D7 on Super Mario
// Land 2 has no GBA counterpart at all.
//
// A CRC32 is not that test and must not be sold as one. It has no reference to
// compare against, so on its own it cannot say a dump is right. What it gives
// the image is an identity: a value that can be matched against a second dump
// of the same cartridge, or against No-Intro, without the image ever reaching
// a PC. That closes the loop the user actually runs today, because they verify
// with zlib.crc32.
//
// It is worth having on the GB path too. A GB dump then reports two
// independent things - the cartridge's own verdict on itself from
// dump_checksum, and an external identity from here - and the two fail in
// different ways.
//
// EXACTLY WHICH CRC32, because there are several and only one is useful here.
// IEEE 802.3, the one zlib.crc32, PNG, gzip and No-Intro all use: polynomial
// 0x04C11DB7 in its reflected form 0xEDB88320, register initialised to all
// ones, input and output reflected, final result inverted. Check value for the
// nine bytes "123456789" is 0xCBF43926. tb_dump_crc32 pins this against values
// taken from Python and will not pass against any other variant.
//
// WHY BIT-SERIAL UNROLLED EIGHT DEEP, AND NOT A TABLE.
// The usual software implementation indexes a 256-entry table of 32-bit words.
// In fabric that is a kilobyte of ROM or a large mux for no gain, because the
// eight unrolled stages below collapse at synthesis into a fixed XOR network:
// each of the 32 output bits is the parity of a handful of input bits, one
// level of LUTs deep in practice. And there is no throughput pressure to
// justify spending anything more. This sits on clk_sys in the streaming path,
// where a GBA sequential 32-bit read costs on the order of 42 cycles for four
// bytes and a GB read costs far more per byte than that. One byte per cycle is
// already an order of magnitude faster than bytes can arrive.
//
// The register holds the *un-finalised* CRC, and crc is the inverted view of
// it. That is deliberate: it means crc is correct at every instant rather than
// only after some end-of-image pulse, so the UI can display a running value,
// and it means the reset state reads 0x00000000 - which is what zlib.crc32
// returns for empty input, so an image of no bytes is not a special case.
//

module dump_crc32 (
    input  wire        clk,
    input  wire        reset,

    // Pulsed when a fresh image starts. Same contract as dump_checksum: this
    // is what makes a second dump comparable with the first rather than a
    // continuation of it.
    input  wire        start,

    input  wire [7:0]  data,
    input  wire        valid,          // data is accepted this cycle

    output wire [31:0] crc,            // finalised, matches zlib.crc32
    output reg  [31:0] count           // bytes seen
);

localparam [31:0] POLY = 32'hEDB88320;   // 0x04C11DB7 reflected
localparam [31:0] INIT = 32'hFFFFFFFF;

// The running register, before the final inversion.
reg [31:0] crc_reg;

// Eight shift-and-conditionally-xor stages, which is the reflected form: the
// low bit leaves the register first, so the incoming byte is xored in at the
// bottom and the polynomial is applied from the top.
function [31:0] crc_byte(input [31:0] c_in, input [7:0] d);
    reg [31:0] c;
    integer i;
begin
    c = c_in ^ {24'd0, d};
    for (i = 0; i < 8; i = i + 1)
        c = (c >> 1) ^ (POLY & {32{c[0]}});
    crc_byte = c;
end
endfunction

assign crc = ~crc_reg;

// count is 32 bits rather than dump_checksum's 24 because a GBA cartridge can
// be 32 MiB, which does not fit in 24. It also matches total_bytes on the
// reader interface, so the two can be compared without a width cast.
always @(posedge clk) begin
    if (reset || start) begin
        crc_reg <= INIT;
        count   <= 32'd0;
    end else if (valid) begin
        crc_reg <= crc_byte(crc_reg, data);
        count   <= count + 32'd1;
    end
end

endmodule

`default_nettype wire
