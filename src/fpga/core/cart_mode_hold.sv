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

// Registered, not muxed. req_out feeds gb_mode_s and gba_mode_s and from
// there the cart_mode of both engines, which is wide fanout on a path that has
// failed timing before. A mux here put write_active in front of all of it and
// cost 0.251 ns and 97 ALMs, measured A/B on one runner with one seed. Driving
// it from a flop instead means the fanout starts at a register.
//
// The cost is that a mode change lands one cycle later. cart_pins registers
// the mode into its own mode_q and runs a settle counter from there, and
// mode_ready is low for the whole of it, so one more cycle in front of a
// settle that is already tens of cycles changes nothing anyone can observe.
//
// Holding by not clocking, rather than by selecting, also means the value
// frozen is the one that was in force when the beat started: on the edge
// write_active rises this register does not load, so it keeps what it had.
reg [1:0] req_q = 2'b00;

always @(posedge clk)
    if (!write_active)
        req_q <= req_in;

assign req_out = req_q;

endmodule

`default_nettype wire
