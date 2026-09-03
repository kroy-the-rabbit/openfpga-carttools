`default_nettype none

// Holds the cartridge mode request still while a write beat is live.
//
// gb_mode_s and gba_mode_s in core_top are combinational in the mode request,
// and cart_pins tears the pins down when the mode changes. So a requester that
// changes its mind while WR# is low cuts the beat: WR# rises and the data is
// released in the same instant, and a cartridge latches write data on the WR#
// rising edge, so what it captures is whatever the floating bus settles to.
// In save space that is a corrupted byte in somebody's save file.
//
// gba_cart_bus sequences its own reset out of that state, raising WR# and
// holding the data for the usual hold before releasing. It cannot do the same
// for a cart_mode drop, because cart_mode is cart_play & cart_power and a
// falling cart_mode means the slot is losing power: driving pins into an
// unpowered cartridge is the worse fault. This module removes the case that
// can be removed, which is the internally chosen one.
//
// Bounded by construction. write_active is high only inside a transaction,
// which is tens of cycles, and if the slot really does lose power the engine
// resets and write_active clears with it, so this cannot latch up.
module cart_mode_hold (
    input  wire        clk,

    // What the requesters want right now.
    input  wire [1:0]  req_in,

    // From gba_cart_bus. High while a write beat is electrically live.
    input  wire        write_active,

    output wire [1:0]  req_out
);

// Tracks the request whenever it is safe to change mode, so the value frozen
// on the cycle write_active rises is the one that was in force when the beat
// started.
reg [1:0] held = 2'b00;

always @(posedge clk)
    if (!write_active)
        held <= req_in;

assign req_out = write_active ? held : req_in;

endmodule

`default_nettype wire
