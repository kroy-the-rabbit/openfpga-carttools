// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none

// A held payload_hold transfers one complete APF cartridge report. Updates arriving
// during a transfer are coalesced to the newest report after acknowledgement.
// The payload cannot change while the destination is sampling it.
module cart_adapter_state (
    input wire clk_host,
    input wire reset_host,
    input wire [31:0] report_host,
    input wire valid_host,
    input wire clk_sys,
    input wire reset_sys,
    output reg [31:0] report,
    output reg valid,
    output reg changed,
    output reg [3:0] report_seq
);
reg [31:0] payload_hold;
reg payload_valid_hold, request, acknowledge;
(* async_reg = "true" *) reg [2:0] ack_sync;
(* async_reg = "true" *) reg [2:0] req_sync;

always @(posedge clk_host) begin
    if (reset_host) begin
        payload_hold <= 0;
        payload_valid_hold <= 0;
        request <= 0;
        ack_sync <= 0;
    end else begin
        ack_sync <= {ack_sync[1:0], acknowledge};
        if (ack_sync[2] == request &&
            (payload_valid_hold != valid_host || payload_hold != report_host)) begin
            payload_hold <= report_host;
            payload_valid_hold <= valid_host;
            request <= ~request;
        end
    end
end

always @(posedge clk_sys) begin
    changed <= 0;
    if (reset_sys) begin
        req_sync <= 0;
        acknowledge <= 0;
        report <= 0;
        valid <= 0;
        report_seq <= 0;
    end else begin
        req_sync <= {req_sync[1:0], request};
        if (req_sync[2] != acknowledge) begin
            report <= payload_hold;
            valid <= payload_valid_hold;
            changed <= 1;
            report_seq <= report_seq + 1'b1;
            acknowledge <= req_sync[2];
        end
    end
end
endmodule
`default_nettype wire
