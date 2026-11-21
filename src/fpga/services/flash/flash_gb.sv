// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

// SST39SF-family flash on a GB cartridge: software ID probe, and chip erase,
// byte program and read-back verify of a 32 KiB image.
//
// Command sequences from the SST39SF010A/020A/040 datasheet:
//   ID entry      5555:AA 2AAA:55 5555:90, read 0000 and 0001
//   ID exit       F0
//   Chip erase    5555:AA 2AAA:55 5555:80 5555:AA 2AAA:55 5555:10, 100 ms max
//   Byte program  5555:AA 2AAA:55 5555:A0 PA:PD, 20 us max
// Cartridge wiring reference: FlashGBX config fc_DMG_FerranteCrafts_32KB.txt,
// fc_DMG_FerranteCrafts_32KB_2.txt and fc_DMG_FerranteCrafts_64KB.txt.
//
// The ID probe strobes WE# on /WR, or on connector pin 31 when use_p31 is set.
// Erase and program always strobe pin 31 and refuse any ID but BF B5. ROM
// bank 1 is selected throughout, so cartridge address equals flash address
// for 0000-7FFF. A write, once started, is only stopped by loss of slot power.
//
// view: 0 none, 1 ID running, 2 ID complete, 3 ID failed, 4 loading the
// image, 5 image loaded, 6 load failed, 7 writing, 8 verified, 9 failed.
// err: 1 file, 2 wrong ID, 3 not blank after erase, 4 power or mode lost,
// 5 read-back mismatch.
module flash_gb #(
    parameter integer WAKE_CYCLES  = 201326592,   // 2 s
    parameter integer ERASE_CYCLES = 20132659,    // 200 ms
    parameter integer PROG_CYCLES  = 4027         // 40 us
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        clk_io,

    input  wire        start_id,
    input  wire        use_p31,
    input  wire        start_load,
    input  wire        start_write,
    input  wire        cancel,
    input  wire        view_clear,
    input  wire        cart_powered,
    input  wire        mode_ready,

    output wire [1:0]  want_mode,
    output reg         busy,
    output reg  [3:0]  view,
    output reg  [1:0]  wphase,       // 0 erasing, 1 programming, 2 verifying

    output reg  [15:0] rom_before,   // {byte at 0000, byte at 0001}
    output reg  [15:0] flash_id,
    output reg  [15:0] rom_after,
    output reg         answered,     // flash_id differs from rom_before
    output reg         unchanged,    // rom_after equals rom_before
    output reg         used_p31,
    output reg         p31_enable,   // pin 31 driven; high outside its strobes

    output reg  [31:0] file_crc,
    output reg  [31:0] read_crc,
    output reg  [2:0]  err,
    output reg  [15:0] mis_count,
    output reg  [15:0] mis_addr,

    // Image staging through restore_file_io, operation 1.
    output reg         io_start,
    output reg         io_active,
    input  wire        io_done,
    input  wire        io_failed,
    input  wire        input_we,
    input  wire [1:0]  input_kind,
    input  wire [12:0] input_index,
    input  wire [31:0] input_data,

    output reg         bus_req,
    output reg         bus_wr,
    output reg         bus_alt,      // strobe pin 31 in place of /WR
    output reg  [15:0] bus_addr,
    output reg  [7:0]  bus_wdata,
    input  wire [7:0]  bus_rdata,
    input  wire        bus_done,
    input  wire        bus_busy
);

localparam [1:0] K_READ = 2'd0, K_MAPPER = 2'd1, K_FLASH = 2'd2;

// {kind, addr, data}
function [25:0] script(input [4:0] n);
    case (n)
        // ID probe
        5'd0:    script = {K_READ,   16'h0000, 8'h00};
        5'd1:    script = {K_READ,   16'h0001, 8'h00};
        5'd2:    script = {K_MAPPER, 16'h2000, 8'h01};
        5'd3:    script = {K_FLASH,  16'h5555, 8'hAA};
        5'd4:    script = {K_FLASH,  16'h2AAA, 8'h55};
        5'd5:    script = {K_FLASH,  16'h5555, 8'h90};
        5'd6:    script = {K_READ,   16'h0000, 8'h00};
        5'd7:    script = {K_READ,   16'h0001, 8'h00};
        5'd8:    script = {K_FLASH,  16'h0000, 8'hF0};
        5'd9:    script = {K_MAPPER, 16'h2000, 8'h01};
        5'd10:   script = {K_MAPPER, 16'h4000, 8'h00};
        5'd11:   script = {K_MAPPER, 16'h0000, 8'h00};
        5'd12:   script = {K_READ,   16'h0000, 8'h00};
        5'd13:   script = {K_READ,   16'h0001, 8'h00};
        // Write: ID check
        5'd14:   script = {K_MAPPER, 16'h2000, 8'h01};
        5'd15:   script = {K_FLASH,  16'h5555, 8'hAA};
        5'd16:   script = {K_FLASH,  16'h2AAA, 8'h55};
        5'd17:   script = {K_FLASH,  16'h5555, 8'h90};
        5'd18:   script = {K_READ,   16'h0000, 8'h00};
        5'd19:   script = {K_READ,   16'h0001, 8'h00};
        5'd20:   script = {K_FLASH,  16'h0000, 8'hF0};
        // Chip erase
        5'd21:   script = {K_FLASH,  16'h5555, 8'hAA};
        5'd22:   script = {K_FLASH,  16'h2AAA, 8'h55};
        5'd23:   script = {K_FLASH,  16'h5555, 8'h80};
        5'd24:   script = {K_FLASH,  16'h5555, 8'hAA};
        5'd25:   script = {K_FLASH,  16'h2AAA, 8'h55};
        5'd26:   script = {K_FLASH,  16'h5555, 8'h10};
        // Byte program prefix
        5'd27:   script = {K_FLASH,  16'h5555, 8'hAA};
        5'd28:   script = {K_FLASH,  16'h2AAA, 8'h55};
        default: script = {K_FLASH,  16'h5555, 8'hA0};
    endcase
endfunction

function [31:0] crc_byte(input [31:0] prior, input [7:0] data);
    reg [31:0] c;
    integer n;
    begin
        c = prior ^ {24'd0, data};
        for (n = 0; n < 8; n = n + 1) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
        crc_byte = c;
    end
endfunction

localparam [4:0] S_IDLE = 5'd0, S_IOPRE = 5'd1, S_IO = 5'd2, S_CRC = 5'd3,
    S_WAKE = 5'd4, S_SCRIPT = 5'd5, S_ARM = 5'd6, S_REQ = 5'd7, S_WAIT = 5'd8,
    S_SDONE = 5'd9, S_IDCHK = 5'd10, S_EWAIT = 5'd11, S_BLANK = 5'd12,
    S_BLANKD = 5'd13, S_PFETCH = 5'd14, S_PDONE = 5'd15, S_PWAIT = 5'd16,
    S_VFETCH = 5'd17, S_VDONE = 5'd18, S_VEND = 5'd19, S_DRAIN = 5'd20;

reg [4:0]  state, ret;
reg [4:0]  pc;
reg [27:0] timer;
reg        mode_owned;
reg        op_write;
reg        fail_l;
reg        file_ok;
reg [15:0] offset;
reg [1:0]  mw;
reg [31:0] crc;
reg [1:0]  t_kind;
reg [15:0] t_addr;
reg [7:0]  t_data;
reg [7:0]  rd_q;

assign want_mode = mode_owned ? 2'b10 : 2'b00;

// The staged image. Written from the file service's clock only while a load
// is in progress.
reg [31:0] staged [0:8191];
reg [2:0]  load_sync;
always @(posedge clk_io) begin
    if (reset) load_sync <= 3'd0;
    else       load_sync <= {load_sync[1:0], state == S_IO};
    if (input_we && input_kind == 2'd1 && load_sync[2])
        staged[input_index] <= input_data;
end

// offset is stable for three clocks before byte_r is used.
reg [31:0] stage_q;
reg [7:0]  byte_r;
always @(posedge clk) begin
    stage_q <= staged[offset[14:2]];
    byte_r  <= stage_q >> (8 * offset[1:0]);
end

wire [25:0] cur = script(pc);
wire last_byte = offset[14:0] == 15'h7FFF;

task fail(input [2:0] code);
    begin
        err    <= code;
        fail_l <= 1'b1;
        state  <= S_DRAIN;
    end
endtask

task go(input [1:0] kind, input [15:0] addr, input [7:0] data, input [4:0] after);
    begin
        t_kind <= kind;
        t_addr <= addr;
        t_data <= data;
        ret    <= after;
        state  <= S_ARM;
    end
endtask

// After a byte is programmed or skipped.
task next_program;
    begin
        mw <= 2'd0;
        if (last_byte) begin
            offset <= 16'd0;
            crc    <= 32'hFFFFFFFF;
            wphase <= 2'd2;
            state  <= S_VFETCH;
        end else begin
            offset <= offset + 16'd1;
            state  <= S_PFETCH;
        end
    end
endtask

always @(posedge clk) begin
    bus_req  <= 1'b0;
    io_start <= 1'b0;

    if (reset) begin
        state      <= S_IDLE;
        ret        <= S_IDLE;
        pc         <= 5'd0;
        timer      <= 28'd0;
        mode_owned <= 1'b0;
        op_write   <= 1'b0;
        fail_l     <= 1'b0;
        file_ok    <= 1'b0;
        offset     <= 16'd0;
        mw         <= 2'd0;
        crc        <= 32'hFFFFFFFF;
        t_kind     <= K_READ;
        t_addr     <= 16'd0;
        t_data     <= 8'd0;
        rd_q       <= 8'd0;
        busy       <= 1'b0;
        view       <= 4'd0;
        wphase     <= 2'd0;
        rom_before <= 16'd0;
        flash_id   <= 16'd0;
        rom_after  <= 16'd0;
        answered   <= 1'b0;
        unchanged  <= 1'b0;
        used_p31   <= 1'b0;
        p31_enable <= 1'b0;
        file_crc   <= 32'd0;
        read_crc   <= 32'd0;
        err        <= 3'd0;
        mis_count  <= 16'd0;
        mis_addr   <= 16'd0;
        io_active  <= 1'b0;
        bus_wr     <= 1'b0;
        bus_alt    <= 1'b0;
        bus_addr   <= 16'd0;
        bus_wdata  <= 8'd0;
    end else begin
        case (state)
            S_IDLE: begin
                if (view_clear) view <= 4'd0;
                if (start_id && cart_powered && !cancel) begin
                    busy       <= 1'b1;
                    fail_l     <= 1'b0;
                    err        <= 3'd0;
                    op_write   <= 1'b0;
                    used_p31   <= use_p31;
                    pc         <= 5'd0;
                    mode_owned <= 1'b1;
                    timer      <= WAKE_CYCLES;
                    view       <= 4'd1;
                    state      <= S_WAKE;
                end else if (start_load) begin
                    busy      <= 1'b1;
                    fail_l    <= 1'b0;
                    err       <= 3'd0;
                    file_ok   <= 1'b0;
                    io_active <= 1'b1;
                    timer     <= 28'd8;
                    view      <= 4'd4;
                    state     <= S_IOPRE;
                end else if (start_write && file_ok && cart_powered && !cancel) begin
                    busy       <= 1'b1;
                    fail_l     <= 1'b0;
                    err        <= 3'd0;
                    op_write   <= 1'b1;
                    used_p31   <= 1'b1;
                    pc         <= 5'd14;
                    mode_owned <= 1'b1;
                    timer      <= WAKE_CYCLES;
                    wphase     <= 2'd0;
                    mis_count  <= 16'd0;
                    mis_addr   <= 16'd0;
                    flash_id   <= 16'd0;
                    read_crc   <= 32'd0;
                    view       <= 4'd7;
                    state      <= S_WAKE;
                end
            end

            // io_active selects this engine's operation and length at the
            // file service a few clocks before the request.
            S_IOPRE: begin
                if (timer != 28'd0) timer <= timer - 28'd1;
                else begin
                    io_start <= 1'b1;
                    state    <= S_IO;
                end
            end

            S_IO: begin
                if (io_done) begin
                    io_active <= 1'b0;
                    if (io_failed) begin
                        err   <= 3'd1;
                        busy  <= 1'b0;
                        view  <= 4'd6;
                        state <= S_IDLE;
                    end else begin
                        offset <= 16'd0;
                        mw     <= 2'd0;
                        crc    <= 32'hFFFFFFFF;
                        state  <= S_CRC;
                    end
                end
            end

            S_CRC: begin
                if (offset == 16'd32768) begin
                    file_crc <= ~crc;
                    file_ok  <= 1'b1;
                    busy     <= 1'b0;
                    view     <= 4'd5;
                    state    <= S_IDLE;
                end else if (mw != 2'd3) begin
                    mw <= mw + 2'd1;
                end else begin
                    mw     <= 2'd0;
                    crc    <= crc_byte(crc, byte_r);
                    offset <= offset + 16'd1;
                end
            end

            S_WAKE: begin
                if (!cart_powered || cancel) fail(3'd4);
                else if (!mode_ready) timer <= WAKE_CYCLES;
                else if (timer != 28'd0) timer <= timer - 28'd1;
                else state <= S_SCRIPT;
            end

            S_SCRIPT: begin
                // One mapper write ahead of the first pin 31 strobe.
                if (used_p31 && (pc == 5'd2 || pc == 5'd14)) p31_enable <= 1'b1;
                go(cur[25:24], cur[23:8], cur[7:0], S_SDONE);
            end

            S_ARM: begin
                if (!cart_powered || !mode_ready) fail(3'd4);
                else if (!bus_busy && !bus_done) begin
                    bus_wr    <= t_kind != K_READ;
                    bus_alt   <= t_kind == K_FLASH && used_p31;
                    bus_addr  <= t_addr;
                    bus_wdata <= t_data;
                    state     <= S_REQ;
                end
            end

            // Address and data were registered one clock ago. The bus was idle
            // then and only a request can move it, so this one-clock request
            // is accepted.
            S_REQ: begin
                bus_req <= 1'b1;
                state   <= S_WAIT;
            end

            S_WAIT: begin
                if (bus_done) begin
                    rd_q  <= bus_rdata;
                    state <= ret;
                end else if (!cart_powered || (!mode_ready && !bus_req)) begin
                    // The bus drops a transaction without done when the mode
                    // goes away.
                    fail(3'd4);
                end
            end

            S_SDONE: begin
                case (pc)
                    5'd0:         rom_before[15:8] <= rd_q;
                    5'd1:         rom_before[7:0]  <= rd_q;
                    5'd6, 5'd18:  flash_id[15:8]   <= rd_q;
                    5'd7, 5'd19:  flash_id[7:0]    <= rd_q;
                    5'd12:        rom_after[15:8]  <= rd_q;
                    5'd13:        rom_after[7:0]   <= rd_q;
                    default: ;
                endcase
                if (pc == 5'd8) p31_enable <= 1'b0;
                case (pc)
                    5'd13: state <= S_DRAIN;
                    5'd20: state <= S_IDCHK;
                    5'd26: begin
                        timer <= ERASE_CYCLES;
                        state <= S_EWAIT;
                    end
                    5'd29: go(K_FLASH, {1'b0, offset[14:0]}, byte_r, S_PDONE);
                    default: begin
                        pc    <= pc + 5'd1;
                        state <= S_SCRIPT;
                    end
                endcase
            end

            S_IDCHK: begin
                if (flash_id != 16'hBFB5) fail(3'd2);
                else begin
                    pc    <= 5'd21;
                    state <= S_SCRIPT;
                end
            end

            S_EWAIT: begin
                if (!cart_powered) fail(3'd4);
                else if (timer != 28'd0) timer <= timer - 28'd1;
                else begin
                    offset <= 16'd0;
                    state  <= S_BLANK;
                end
            end

            S_BLANK: go(K_READ, {1'b0, offset[14:0]}, 8'h00, S_BLANKD);

            S_BLANKD: begin
                if (rd_q != 8'hFF) begin
                    mis_addr <= offset;
                    fail(3'd3);
                end else if (last_byte) begin
                    offset <= 16'd0;
                    mw     <= 2'd0;
                    wphase <= 2'd1;
                    state  <= S_PFETCH;
                end else begin
                    offset <= offset + 16'd1;
                    state  <= S_BLANK;
                end
            end

            S_PFETCH: begin
                if (mw != 2'd3) mw <= mw + 2'd1;
                else if (byte_r == 8'hFF) next_program();
                else begin
                    pc    <= 5'd27;
                    state <= S_SCRIPT;
                end
            end

            S_PDONE: begin
                timer <= PROG_CYCLES;
                state <= S_PWAIT;
            end

            S_PWAIT: begin
                if (timer != 28'd0) timer <= timer - 28'd1;
                else next_program();
            end

            S_VFETCH: begin
                if (mw != 2'd3) mw <= mw + 2'd1;
                else go(K_READ, {1'b0, offset[14:0]}, 8'h00, S_VDONE);
            end

            S_VDONE: begin
                crc <= crc_byte(crc, rd_q);
                if (rd_q != byte_r) begin
                    if (mis_count == 16'd0) mis_addr <= offset;
                    if (mis_count != 16'hFFFF) mis_count <= mis_count + 16'd1;
                end
                mw <= 2'd0;
                if (last_byte) state <= S_VEND;
                else begin
                    offset <= offset + 16'd1;
                    state  <= S_VFETCH;
                end
            end

            S_VEND: begin
                read_crc <= ~crc;
                if (mis_count != 16'd0) fail(3'd5);
                else state <= S_DRAIN;
            end

            // The mode is released only with the bus idle.
            S_DRAIN: begin
                if (!bus_busy || !cart_powered) begin
                    mode_owned <= 1'b0;
                    p31_enable <= 1'b0;
                    busy       <= 1'b0;
                    answered   <= flash_id != rom_before;
                    unchanged  <= rom_after == rom_before;
                    view       <= op_write ? (fail_l ? 4'd9 : 4'd8)
                                           : (fail_l ? 4'd3 : 4'd2);
                    state      <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
