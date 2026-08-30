// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

//
// dump_checksum.sv - the cartridge's own verdict on the dump, while it runs
//
// A Game Boy cartridge stores a 16-bit sum of every one of its bytes at
// header 0x014E, big endian, excluding those two bytes themselves. Nothing in
// the console checks it. It is, however, the only description of a cartridge's
// entire contents that the cartridge carries, and it is therefore the only
// way a dump can be judged without a reference image.
//
// WHY THIS EXISTS, and it is not a nicety.
//
// Super Mario Land 2 dumped once with a floating D7. 105,121 of its 524,288
// bytes came back with bit 7 wrong, in both directions, and the core reported
// success. Identification had passed it: the header read back with bit 7 set
// on every byte, and the 8-bit header checksum still balanced, because
// twenty-five bytes each shifted by 0x80 sum to 0xC80 whose low byte is 0x80,
// and the stored checksum byte shifted by 0x80 as well. The two cancel. An
// 8-bit checksum cannot see a uniform bit-7 offset.
//
// The stability check did not catch it either. cart_identify_gb reads the
// header twice and compares, and D7 was consistently high across that window.
// Consistent and wrong is indistinguishable from correct by that test.
//
// So the screen said "checksum ok" beside a garbled title and offered the
// dump, and the fault was found afterwards on a PC. This is what closes that
// gap: the reader already streams every byte past here, so summing them costs
// an adder and a comparison, and the answer arrives before the card is pulled.
//
// It is a sum, not a CRC. It cannot localise an error and two compensating
// faults would cancel. What it does catch is every fault seen so far: a
// stuck or floating data line, a short image, a bank read twice, a shifted
// window. That is worth an adder.
//

module dump_checksum (
    input  wire        clk,
    input  wire        reset,

    // Pulsed when a fresh image starts. count is the linear offset of the
    // next byte, so it must be right or the two header bytes are excluded
    // from the wrong place.
    input  wire        start,

    input  wire [7:0]  data,
    input  wire        valid,          // data is accepted this cycle

    output reg  [15:0] sum,            // every byte but 0x14E and 0x14F
    output reg  [15:0] stored,         // what the cartridge claims, big endian
    output reg  [23:0] count           // bytes seen
);

localparam [23:0] OFF_HI = 24'h00_014E;
localparam [23:0] OFF_LO = 24'h00_014F;

always @(posedge clk) begin
    if (reset || start) begin
        sum    <= 16'd0;
        stored <= 16'd0;
        count  <= 24'd0;
    end else if (valid) begin
        count <= count + 24'd1;

        // The two checksum bytes are captured rather than summed. Including
        // them would make the comparison self-referential and always fail.
        if (count == OFF_HI)      stored[15:8] <= data;
        else if (count == OFF_LO) stored[7:0]  <= data;
        else                      sum <= sum + {8'd0, data};
    end
end

endmodule

`default_nettype wire
