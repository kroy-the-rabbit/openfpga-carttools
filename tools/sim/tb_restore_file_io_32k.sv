// SOURCES: src/fpga/services/restore/restore_file_io.sv tools/sim/tb_restore_file_io.sv
// The complete file-service bench at the MBC3 geometry: 32,768-byte save
// input, recovery resize, write, reopen and readback.
`default_nettype none
`timescale 1ns/1ps

module tb_restore_file_io_32k;
tb_restore_file_io #(.SAVE_BYTES(32768)) bench ();
endmodule

`default_nettype wire
