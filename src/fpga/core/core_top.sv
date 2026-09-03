//
// openFPGA-CartTools top level for Analogue Pocket
//
// What is left after the emulator was removed. The port list is unchanged,
// because it is the APF contract with the Pocket rather than anything this
// core chose, but almost everything behind it is gone: no CPU, no PPU, no
// APU, no DMA, no timers, no SDRAM, no PSRAM, no save states.
//
// What survives is the path to the cartridge connector and the path to the
// screen:
//
//   core_bridge_cmd   APF host commands, including 0x00B1 which is how this
//                     core learns the slot is selected and powered
//   cart_pins         the only module allowed to drive cartridge pins
//   gba_cart_bus      the GBA protocol engine behind it
//   video_adapter     240x160 framebuffer, scanned out to the Pocket scaler
//
// Everything the Pocket offers and this core does not use is tied off
// explicitly below rather than left floating, because an unused inout that
// the fitter is free to drive is a hardware risk, not a lint warning.
//
`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);


// ============================================================
// Unused physical interfaces
//
// CartTools reads cartridges and draws text. It has no use for the memories
// the emulator needed, and no use for the ports the Pocket exposes for other
// purposes. Every one of them is driven to a safe inactive state here.
//
// The cartridge pins are NOT in this list. They belong to cart_pins, which
// is the only module permitted to name them, and tools/sim/check_pin_isolation.py
// fails the test suite if that stops being true.
// ============================================================

// cellular psram, both chips: deselected, not clocked, bus released
assign cram0_a     = 6'h0;
assign cram0_dq    = {16{1'bZ}};
assign cram0_clk   = 1'b0;
assign cram0_adv_n = 1'b1;
assign cram0_cre   = 1'b0;
assign cram0_ce0_n = 1'b1;
assign cram0_ce1_n = 1'b1;
assign cram0_oe_n  = 1'b1;
assign cram0_we_n  = 1'b1;
assign cram0_ub_n  = 1'b1;
assign cram0_lb_n  = 1'b1;

assign cram1_a     = 6'h0;
assign cram1_dq    = {16{1'bZ}};
assign cram1_clk   = 1'b0;
assign cram1_adv_n = 1'b1;
assign cram1_cre   = 1'b0;
assign cram1_ce0_n = 1'b1;
assign cram1_ce1_n = 1'b1;
assign cram1_oe_n  = 1'b1;
assign cram1_we_n  = 1'b1;
assign cram1_ub_n  = 1'b1;
assign cram1_lb_n  = 1'b1;

// sdram: clock stopped, every command line inactive, data bus released
assign dram_a     = 13'h0;
assign dram_ba    = 2'b00;
assign dram_dq    = {16{1'bZ}};
assign dram_dqm   = 2'b00;
assign dram_clk   = 1'b0;
assign dram_cke   = 1'b0;
assign dram_ras_n = 1'b1;
assign dram_cas_n = 1'b1;
assign dram_we_n  = 1'b1;

// sram
assign sram_a    = 17'h0;
assign sram_dq   = {16{1'bZ}};
assign sram_oe_n = 1'b1;
assign sram_we_n = 1'b1;
assign sram_ub_n = 1'b1;
assign sram_lb_n = 1'b1;

// link port: input only, so nothing this core does can drive a connected cable
assign port_tran_so     = 1'bZ;
assign port_tran_so_dir = 1'b0;
assign port_tran_si     = 1'bZ;
assign port_tran_si_dir = 1'b0;
assign port_tran_sck     = 1'bZ;
assign port_tran_sck_dir = 1'b0;
assign port_tran_sd     = 1'bZ;
assign port_tran_sd_dir = 1'b0;

// infrared: LED off and the receiver powered down
assign port_ir_tx         = 1'b0;
assign port_ir_rx_disable = 1'b1;

// solder pads, debug uart, RFU i2c, RFU pll feed
assign dbg_tx    = 1'b1;
assign user1     = 1'b0;
assign aux_sda   = 1'bZ;
assign aux_scl   = 1'b1;
assign vpll_feed = 1'bZ;

// Audio. There is nothing to play, so the I2S pins are held low rather than
// clocked with silence. This is the one tie-off here that is an assumption
// about the Pocket rather than a fact about this core: if the hardware turns
// out to want a running MCLK even with no audio, the fix is to bring back
// audio_mixer feeding it zeroes. Recorded in docs/STATUS.md as unverified.
assign audio_mclk = 1'b0;
assign audio_dac  = 1'b0;
assign audio_lrck = 1'b0;

assign bridge_endian_little = 1'b0;


// ============================================================
// Clocks
//
// The PLL is inherited untouched. Regenerating it would mean regenerating
// Altera IP for no gain: clk_sys is fast enough for cartridge timing and
// clk_vid is what the scaler expects, and both are already constrained.
// ============================================================

wire clk_sys;        // 100.663 MHz, everything below the bridge
wire clk_sys_90;     // unused here, was the SDRAM output clock
wire clk_vid;        // 8.388608 MHz, video pixel clock
wire clk_vid_90;     // 90 degrees, video DDR output
wire pll_core_locked;
wire pll_core_locked_s;

synch_3 s_pll_locked (pll_core_locked, pll_core_locked_s, clk_74a);

mf_pllbase mp1 (
    .refclk   ( clk_74a ),
    .rst      ( 1'b0 ),
    .outclk_0 ( clk_sys ),
    .outclk_1 ( clk_sys_90 ),
    .outclk_2 ( clk_vid ),
    .outclk_3 ( clk_vid_90 ),
    .locked   ( pll_core_locked )
);


// ============================================================
// APF bridge
// ============================================================

wire            reset_n;
wire    [31:0]  cmd_bridge_rd_data;

wire            status_boot_done  = pll_core_locked_s;
wire            status_setup_done = pll_core_locked_s;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1'b1;
wire            dataslot_requestread_ok  = 1'b1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1'b1;
wire            dataslot_requestwrite_ok  = 1'b1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire    [31:0]  rtc_epoch_seconds;
wire    [31:0]  rtc_date_bcd;
wire    [31:0]  rtc_time_bcd;
wire            rtc_valid;

// APF command 0x00B1. cart_play is the user having selected Play Cartridge,
// cart_power is the slot actually being powered. Both must be true before a
// single cartridge pin is driven, which is why gba_cart_bus takes their AND
// as its cart_mode and cart_pins takes it as its mode select.
wire            cart_play;
wire            cart_power;
wire    [31:0]  cart_adapter_id;
wire            cart_mode_74a = cart_play & cart_power;

// Save states are gone with the emulator. Reporting them unsupported is not
// cosmetic: it is what stops the host asking for one. The handshake lines are
// still driven, and driven to a failure answer, so that a host that asks
// anyway gets a clean refusal instead of a bus with no driver.
wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'h0;
wire    [31:0]  savestate_size        = 32'h0;
wire    [31:0]  savestate_maxloadsize = 32'h0;

wire            savestate_start;
wire            savestate_start_ack  = 1'b1;
wire            savestate_start_busy = 1'b0;
wire            savestate_start_ok   = 1'b0;
wire            savestate_start_err  = 1'b1;

wire            savestate_load;
wire            savestate_load_ack  = 1'b1;
wire            savestate_load_busy = 1'b0;
wire            savestate_load_ok   = 1'b0;
wire            savestate_load_err  = 1'b1;

wire            osnotify_inmenu;

// The target_dataslot_* path is how a core moves a file to or from the SD
// card, and it is the only path that lets the core choose the filename. It is
// driven entirely by dump_engine, which lives in this clock domain for that
// reason. Read and getfile are not issued: nothing here loads a file, and the
// only thing getfile would tell us is where the user's ROM came from.
wire            target_dataslot_read    = 1'b0;
wire            target_dataslot_getfile;

wire            target_dataslot_write;
wire            target_dataslot_openfile;
wire            target_dataslot_flush;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

wire    [15:0]  target_dataslot_id;
wire    [31:0]  target_dataslot_slotoffset;
wire    [31:0]  target_dataslot_bridgeaddr;
wire    [31:0]  target_dataslot_length;

wire    [31:0]  target_buffer_param_struct;

// 0x0190 Get filename writes its response into core memory, and dump_engine
// owns the window it writes to.
wire    [31:0]  target_buffer_resp_struct;

wire    [9:0]   datatable_addr = 10'h0;
wire            datatable_wren = 1'b0;
wire    [31:0]  datatable_data = 32'h0;
wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                    ( clk_74a ),
    .reset_n                ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .cart_play              ( cart_play ),
    .cart_power             ( cart_power ),
    .cart_adapter_id        ( cart_adapter_id ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    .target_dataslot_flush      ( target_dataslot_flush ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);


// Two answering agents now, so this is a decode rather than a pass through.
// dump_engine claims 0x6xxxxxxx and 0x7xxxxxxx and answers in the same number
// of cycles core_bridge_cmd does, which is what lets the choice be a plain
// mux with no handshake: whichever one was addressed is holding the right
// word by the time APF samples it.
wire [31:0] dump_bridge_rd_data;
wire        dump_bridge_rd_hit;

always @(*) begin
    bridge_rd_data = dump_bridge_rd_hit ? dump_bridge_rd_data
                                        : cmd_bridge_rd_data;
end


// ============================================================
// Cartridge slot
//
// gba_cart_bus is inherited from Rai's cartridge-support branch. Its logic is
// unchanged; it presents a flat engine interface instead of naming pins.
// cart_pins owns the pins and holds them at the safe idle whenever cart_mode
// is low, which is the state this core boots into and stays in until the
// Pocket says the slot is selected and powered.
//
// ============================================================

wire cart_mode_s;
synch_3 s_cart_mode (cart_mode_74a, cart_mode_s, clk_sys);

wire [31:0] cart_bus_rdata;
wire        cart_bus_done;
wire        cart_bus_busy;

// Engine interface between gba_cart_bus and cart_pins. No module below
// cart_pins names a connector pin.
wire [15:0] gba_ad_out;
wire        gba_ad_oe;
wire [7:0]  gba_hi_out;
wire        gba_hi_oe;
wire [3:0]  gba_ctl_out;
wire        gba_p30_out;
wire        gba_p30_oe;
wire [15:0] gba_ad_in;
wire [7:0]  gba_hi_in;
wire        cart_mode_ready;

// Three masters now, and still no arbiter, for the reason the GB bus already
// records: they cannot be running at the same time. cart_identify_gba runs
// inside cart_probe, which is not allowed to start while a dump is in
// progress; gba_size_probe runs once, after a probe has finished and before a
// dump can be started, because dump_ready requires a size; and cart_dump_gba
// runs only during a dump. So the select is two flags rather than an arbiter,
// and the ordering that makes that safe is enforced where the operations are
// started, not here - by cart_engine_busy, which every dump start is gated
// on. That gate is load bearing rather than tidy: this mux will silently take
// the bus away from a master that has no timeout, and the first version of it
// let Y do exactly that during an identification.
//
// The select order matters: dump_busy wins over probe_sizing, because a dump
// cannot begin until the size probe has finished and released the bus, and if
// both were somehow high the dump is the one holding the connector mode.
wire        id_req;
wire        id_wr;
wire [27:0] id_addr;
wire [1:0]  id_acc;
wire [31:0] id_wdata;

wire        sz_req;
wire        sz_wr;
wire [27:0] sz_addr;
wire [1:0]  sz_acc;
wire [31:0] sz_wdata;

wire        gdmp_req;
wire        gdmp_wr;
wire [27:0] gdmp_addr;
wire [1:0]  gdmp_acc;
wire [31:0] gdmp_wdata;

wire        probe_sizing;      // gba_size_probe busy
wire        dump_busy;

// Declared here rather than at its assignment because the bus ownership flag
// below needs it and that has to sit next to cart_probe.
wire        sz_start;

// gba_save_scan, the fourth master. It reads the whole ROM once, after the
// size probe, looking for the string the SDK's save library leaves in the
// image. Named save_scan throughout: scan_start already belongs to
// cart_probe, which is what the A button does, and the two are unrelated.
wire        save_scan_busy;
// Assigned where the scanner is instantiated. Declared here because
// cart_engine_busy needs it and that has to sit next to cart_probe, the same
// reason sz_start is declared up here.
wire        save_scan_start;
wire        ee_probe_busy, ee_probe_start;
wire        ee_req, ee_wr;
wire [27:0] ee_addr;
wire [1:0]  ee_acc;
wire [31:0] ee_wdata;
wire        scn_req, scn_wr;
wire [27:0] scn_addr;
wire [1:0]  scn_acc;
wire [31:0] scn_wdata;

// The select order follows the one already here: a dump wins over everything,
// then the save scan, then the size probe, then identification. The save scan
// is started by the size probe finishing, so those two are never both busy
// and the order between them states intent rather than arbitrating.
wire        gba_req_mux   = dump_busy ? gdmp_req   : ee_probe_busy ? ee_req   : save_scan_busy ? scn_req   : probe_sizing ? sz_req   : id_req;
wire        gba_wr_mux    = dump_busy ? gdmp_wr    : ee_probe_busy ? ee_wr    : save_scan_busy ? scn_wr    : probe_sizing ? sz_wr    : id_wr;
wire [27:0] gba_addr_mux  = dump_busy ? gdmp_addr  : ee_probe_busy ? ee_addr  : save_scan_busy ? scn_addr  : probe_sizing ? sz_addr  : id_addr;
wire [1:0]  gba_acc_mux   = dump_busy ? gdmp_acc   : ee_probe_busy ? ee_acc   : save_scan_busy ? scn_acc   : probe_sizing ? sz_acc   : id_acc;
wire [31:0] gba_wdata_mux = dump_busy ? gdmp_wdata : ee_probe_busy ? ee_wdata : save_scan_busy ? scn_wdata : probe_sizing ? sz_wdata : id_wdata;

// High while a write beat is live on the GBA bus. Used to hold the mode
// request still, below.
wire        gba_write_active;

gba_cart_bus cart_bus (
    .clk                    ( clk_sys ),
    .reset                  ( ~pll_core_locked ),
    // Not cart_mode_s alone: the engine must be off while the pins are in GB
    // mode or still turning round.
    .cart_mode              ( gba_mode_s ),

    .req                    ( gba_req_mux ),
    .wr                     ( gba_wr_mux ),
    .addr                   ( gba_addr_mux ),
    .acc                    ( gba_acc_mux ),
    .wdata                  ( gba_wdata_mux ),
    .rdata                  ( cart_bus_rdata ),
    .done                   ( cart_bus_done ),
    .busy                   ( cart_bus_busy ),
    .write_active           ( gba_write_active ),

    .e_ad_out               ( gba_ad_out ),
    .e_ad_oe                ( gba_ad_oe ),
    .e_hi_out               ( gba_hi_out ),
    .e_hi_oe                ( gba_hi_oe ),
    .e_ctl_out              ( gba_ctl_out ),
    .e_p30_out              ( gba_p30_out ),
    .e_p30_oe               ( gba_p30_oe ),
    .e_ad_in                ( gba_ad_in ),
    .e_hi_in                ( gba_hi_in )
);

// The GB engine. Same connector, different signal meanings; see
// docs/HARDWARE-NOTES.md section 5. It is enabled only while cart_pins is
// carrying GB mode, so it cannot drive while the GBA engine owns the pins.
wire [15:0] gb_ad_out;
wire        gb_ad_oe;
wire [7:0]  gb_hi_out;
wire        gb_hi_oe;
wire [3:0]  gb_ctl_out;
wire        gb_p30_out;
wire        gb_p30_oe;
wire [15:0] gb_ad_in;
wire [7:0]  gb_hi_in;

wire [1:0]  probe_mode;
wire        probe_answered_gba;

// A dump holds the connector in its own mode for as long as it runs.
// cart_probe parks the mode at idle when it finishes and idle drives pin 30
// low, which is /RES on a Game Boy cartridge, so leaving the probe in charge
// of the mode would put the cartridge back into reset partway through being
// read.
//
// Two bits rather than one, because a GBA dump has to hold 2'b01 for the same
// reason a GB dump holds 2'b10. The size probe asks for the same thing and for
// the same reason: it runs after cart_probe has already parked the mode, so it
// would otherwise be reading a connector that is not connected to anything.
//
// A dump outranks the size probe, which outranks cart_probe. That ordering is
// never exercised - the three cannot overlap, see the bus mux above - and it
// is written this way so that if they ever did, the one holding a cartridge
// mid-transaction wins.
wire [1:0]  dump_want_mode;
wire        sz_want_gba;
wire        save_scan_want_gba;
// save_scan_start is in the mode request as well as save_scan_want_gba, and
// that is not belt and braces. gba_size_probe drops want_gba in the same cycle
// it raises done, and the scan raises its own a cycle after that, so without
// this the request falls back to parked idle for exactly one cycle and
// cart_pins begins a turnaround nobody wanted.
wire [1:0]  cart_mode_req_raw = (dump_want_mode != 2'b00) ? dump_want_mode :
                                (sz_want_gba | save_scan_want_gba |
                                 save_scan_start |
                                 ee_probe_busy | ee_probe_start) ? 2'b01
                                                           : probe_mode;

// A mode change tears the pins down, and gb_mode_s and gba_mode_s below are
// combinational in this request, so a requester that changes its mind while
// WR# is low cuts the write beat. cart_mode_hold.sv carries the reasoning and
// tb_cart_mode_hold the proof.
wire [1:0]  cart_mode_req;

cart_mode_hold mode_hold (
    .clk          ( clk_sys ),
    .req_in       ( cart_mode_req_raw ),
    .write_active ( gba_write_active ),
    .req_out      ( cart_mode_req )
);

wire        gb_mode_s  = cart_mode_s && (cart_mode_req == 2'b10) && cart_mode_ready;
wire        gba_mode_s = cart_mode_s && (cart_mode_req == 2'b01) && cart_mode_ready;

wire        gbid_req;
wire        gbid_wr;
wire [15:0] gbid_addr;
wire [7:0]  gbid_wdata;
wire [7:0]  gb_bus_rdata;
wire        gb_bus_done;
wire        gb_bus_busy;

// Two masters for one bus, and still no arbiter, for the same reason as
// before: they cannot both be running. cart_probe is not allowed to start
// while a dump is in progress and a dump cannot start unless a probe has
// already finished, so the select is the dump's own busy flag.
wire        dmp_req;
wire        dmp_wr;
wire [15:0] dmp_addr;
wire [7:0]  dmp_wdata;

wire        gb_req_mux   = dump_busy ? dmp_req   : gbid_req;
wire        gb_wr_mux    = dump_busy ? dmp_wr    : gbid_wr;
wire [15:0] gb_addr_mux  = dump_busy ? dmp_addr  : gbid_addr;
wire [7:0]  gb_wdata_mux = dump_busy ? dmp_wdata : gbid_wdata;

gb_cart_bus gb_bus (
    .clk       ( clk_sys ),
    .reset     ( ~pll_core_locked ),
    .gb_mode   ( gb_mode_s ),

    .req       ( gb_req_mux ),
    .wr        ( gb_wr_mux ),
    .addr      ( gb_addr_mux ),
    .wdata     ( gb_wdata_mux ),
    .rdata     ( gb_bus_rdata ),
    .done      ( gb_bus_done ),
    .busy      ( gb_bus_busy ),

    .e_ad_out  ( gb_ad_out ),
    .e_ad_oe   ( gb_ad_oe ),
    .e_hi_out  ( gb_hi_out ),
    .e_hi_oe   ( gb_hi_oe ),
    .e_ctl_out ( gb_ctl_out ),
    .e_p30_out ( gb_p30_out ),
    .e_p30_oe  ( gb_p30_oe ),
    .e_ad_in   ( gb_ad_in ),
    .e_hi_in   ( gb_hi_in )
);


// cart_pins owns the connector pins and muxes the engines onto them by mode.
// 00 idle, 01 GBA, 10 GB, 11 idle. cart_probe drives the mode.
cart_pins cart_pins_inst (
    .clk                    ( clk_sys ),
    .reset                  ( ~pll_core_locked ),
    .mode                   ( cart_mode_s ? cart_mode_req : 2'b00 ),
    .mode_ready             ( cart_mode_ready ),

    .gba_ad_out             ( gba_ad_out ),
    .gba_ad_oe              ( gba_ad_oe ),
    .gba_hi_out             ( gba_hi_out ),
    .gba_hi_oe              ( gba_hi_oe ),
    .gba_ctl_out            ( gba_ctl_out ),
    .gba_p30_out            ( gba_p30_out ),
    .gba_p30_oe             ( gba_p30_oe ),
    .gba_ad_in              ( gba_ad_in ),
    .gba_hi_in              ( gba_hi_in ),

    .gb_ad_out              ( gb_ad_out ),
    .gb_ad_oe               ( gb_ad_oe ),
    .gb_hi_out              ( gb_hi_out ),
    .gb_hi_oe               ( gb_hi_oe ),
    .gb_ctl_out             ( gb_ctl_out ),
    .gb_p30_out             ( gb_p30_out ),
    .gb_p30_oe              ( gb_p30_oe ),
    .gb_ad_in               ( gb_ad_in ),
    .gb_hi_in               ( gb_hi_in ),

    .cart_tran_bank2        ( cart_tran_bank2 ),
    .cart_tran_bank2_dir    ( cart_tran_bank2_dir ),
    .cart_tran_bank3        ( cart_tran_bank3 ),
    .cart_tran_bank3_dir    ( cart_tran_bank3_dir ),
    .cart_tran_bank1        ( cart_tran_bank1 ),
    .cart_tran_bank1_dir    ( cart_tran_bank1_dir ),
    .cart_tran_bank0        ( cart_tran_bank0 ),
    .cart_tran_bank0_dir    ( cart_tran_bank0_dir ),
    .cart_tran_pin30        ( cart_tran_pin30 ),
    .cart_tran_pin30_dir    ( cart_tran_pin30_dir ),
    .cart_pin30_pwroff_reset( cart_pin30_pwroff_reset ),
    .cart_tran_pin31        ( cart_tran_pin31 ),
    .cart_tran_pin31_dir    ( cart_tran_pin31_dir )
);


// ============================================================
// Identification
//
// One button, one operation. A identifies whatever is in the slot, and an
// identification also starts by itself when the Pocket powers the slot, so
// the common case needs no button at all.
//
// Re-identifying is always safe: it is sixteen reads of the header twice
// over, no writes, and gba_cart_bus refuses to pulse WR# in ROM space.
// ============================================================

wire [31:0] cont1_key_s;
synch_3 #(.WIDTH(32)) s_cont1 (cont1_key, cont1_key_s, clk_sys);

wire key_a = cont1_key_s[4];
reg  key_a_d;
wire key_a_edge = key_a & ~key_a_d;

// X dumps the cartridge's ROM, Y backs up its save. Neither is on a face
// button a user reaches for first. X cannot do anything that is not a file
// write to the card; Y writes two bytes to the cartridge, the ones that open
// and shut its RAM gate, and cart_save_gb's header says why that is the whole
// mechanism the hardware provides and what guards it.
wire key_x = cont1_key_s[6];
reg  key_x_d;
wire key_x_edge = key_x & ~key_x_d;

wire key_y = cont1_key_s[7];
reg  key_y_d;
wire key_y_edge = key_y & ~key_y_d;

// Which end of a bridge word the first byte of a byte array goes in, for
// things this core presents to APF.
//
// 1, measured from bytes that actually reached the card. The first dump to
// land wrote each group of four reversed against byte_order 0, so APF takes
// byte 0 of a read from the low byte.
//
// It is the opposite of the direction APF writes in: 0x0190's reply arrived
// with the first character in the high byte. Reads and writes are not
// symmetric here, which is worth knowing before reasoning from one to the
// other, as this core did, twice.
//
// A constant now. It was a register the diagnostics page could flip, back
// when which value was right had never been measured; it has since been
// measured on every dump this core has written. dump_engine still searches
// from it, so a wrong answer here costs a few extra attempts rather than a
// failed dump.
localparam byte_order = 1'b1;

// Where the path APF is given is rooted. Same reasoning as byte_order and the
// same evidence: the first hardware attempt returned 4, malformed path, for a
// path that looked right, and each candidate root costs a Quartus run to try.
// dump_path_gen documents what each value means; 0 is /Assets/carttools, the
// root every dump on the card was written under.
localparam [2:0] path_style = 3'd0;

// Either edge, not just the rising one. On the falling edge the slot has been
// unpowered or the cartridge pulled, and re-running is what clears the screen:
// the identifier answers immediately with "slot not powered" rather than
// leaving the name of a cartridge that is no longer there on display.
reg  cart_mode_d;
wire cart_mode_change = cart_mode_s ^ cart_mode_d;
wire cart_mode_fell   = cart_mode_change & ~cart_mode_s;

// The rising edge is not like the falling one. cart_play & cart_power says the
// Pocket has decided to power the slot, not that the rail and the level
// translators have settled, so the first probe does not fire on the edge.
//
// This delay alone did NOT fix the hardware symptom it was first written for:
// the first identification after launch returned UNRECOGNISED while every
// rescan succeeded. That fault is reset recovery, and the fix for it is
// cart_probe's WAKE_CYCLES, because the cartridge is held in reset for the
// whole of this window: cart_pins only releases pin 30 once mode_ready
// asserts. This is kept for what it does do, which is to not read a rail that
// was announced a microsecond ago. 100 ms at clk_sys 100.663296 MHz.
localparam [28:0] CART_WAKE_CYCLES = 29'd201_326_592;   // ~2 s at 100.663296 MHz

reg [28:0] cart_wake;
reg        cart_wake_pulse;

always @(posedge clk_sys) begin
    cart_wake_pulse <= 1'b0;
    if (~pll_core_locked || !cart_mode_s) begin
        cart_wake <= CART_WAKE_CYCLES;
    end else if (cart_wake != 29'd0) begin
        cart_wake <= cart_wake - 29'd1;
        if (cart_wake == 29'd1) cart_wake_pulse <= 1'b1;
    end
end

always @(posedge clk_sys) begin
    key_a_d      <= key_a;
    key_x_d      <= key_x;
    key_y_d      <= key_y;
    cart_mode_d  <= cart_mode_s;
end

wire        id_busy;
wire        id_done;
wire [2:0]  id_result;
wire [95:0] id_title;
wire [31:0] id_game_code;
wire [15:0] id_maker_code;
wire [7:0]  id_device_type;
wire [7:0]  id_sw_version;
wire        id_fixed_ok;
wire        id_checksum_ok;
wire        id_reserved_ok;
wire [255:0] id_raw_words;
wire [7:0]   id_checksum_read;
wire [7:0]   id_checksum_calc;

wire         gbid_busy;
wire         gbid_done;
wire [2:0]   gbid_result;
wire [119:0] gbid_title;
wire [7:0]   gbid_cgb_flag;
wire [7:0]   gbid_cart_type;
wire [7:0]   gbid_rom_size;
wire [7:0]   gbid_ram_size;
wire [7:0]   gbid_sw_version;
wire         gbid_checksum_ok;
wire [207:0] gbid_raw_bytes;
wire [7:0]   gbid_checksum_read;
wire [7:0]   gbid_checksum_calc;

wire        probe_busy;
wire        probe_done;

// Something other than a dump owns a cartridge bus, and cannot survive losing
// it. Both probes wait on a done that only arrives if their own requests
// reach the bus, and neither has a timeout or a cart_mode abort while it is
// waiting, so a dump started underneath either one strands it with its busy
// flag high and nothing but a core reload to clear it. The bus mux hands the
// bus to whichever flag is set, so the ordering has to be enforced here,
// where operations start, rather than there.
//
// sz_start is in the list because of a one cycle hole. cart_probe clears busy
// in the same block that raises done, so in the cycle probe_done pulses,
// probe_busy has already fallen and probe_sizing has not yet risen: the bus
// is spoken for and no flag says so.
// The save scan is deliberately NOT in this list, and that is the second half
// of a bug this shipped once. It runs for seconds on a large cartridge, so
// gating dump_ready on it made every dump option vanish for the whole scan;
// combined with the scan hanging, they never came back. A ROM dump has to
// stay available throughout. The bus conflict that would create is handled by
// resetting the scanner when a dump starts, below, rather than by making the
// user wait for it.
wire        cart_engine_busy = probe_busy | probe_sizing | sz_start;

// A scan is about to run: the cartridge woke, the slot changed, or A was
// pressed. Named rather than left inline in cart_probe's instantiation
// because the dump display has to clear on exactly the same event, and two
// copies of this expression would drift.
wire        scan_start = (cart_wake_pulse | cart_mode_fell | key_a_edge) &
                         ~dump_busy & ~probe_sizing & ~sz_start;
wire [2:0]  platform;
wire        gb_start, gba_start;

cart_probe probe (
    .clk          ( clk_sys ),
    .reset        ( ~pll_core_locked ),
    // A probe during a dump would drive the same bus and move the mode out
    // from under it. There is no queueing: a press during a dump is dropped.
    //
    // The size probe has to be in that list for a harder reason than tidiness.
    // The bus mux above hands the GBA bus to whichever of the three is
    // running, so a probe started underneath a size probe would have its
    // requests muxed away and would wait for a done that is never coming -
    // with cart_probe's busy flag stuck high, and reset the only way out. The
    // sizing window is a few tens of microseconds, so what is dropped here is
    // a button press nobody could time deliberately.
    .start        ( scan_start ),
    .cart_powered ( cart_mode_s ),
    .busy         ( probe_busy ),
    .done         ( probe_done ),
    .mode         ( probe_mode ),
    .mode_ready   ( cart_mode_ready ),
    .gb_start     ( gb_start ),
    .gb_done      ( gbid_done ),
    .gb_result    ( gbid_result ),
    .gba_start    ( gba_start ),
    .gba_done     ( id_done ),
    .gba_result   ( id_result ),
    .platform     ( platform ),
    .answered_gba ( probe_answered_gba )
);

// Latched so the screen keeps the last result while a new probe runs.
reg [3:0] id_seq;
always @(posedge clk_sys) begin
    if (~pll_core_locked) id_seq <= 4'd0;
    else if (probe_done)  id_seq <= id_seq + 4'd1;
end

reg id_valid;
always @(posedge clk_sys) begin
    if (~pll_core_locked)      id_valid <= 1'b0;
    else if (cart_mode_change) id_valid <= 1'b0;
    else if (probe_done)       id_valid <= 1'b1;
end

cart_identify_gb identify_gb (
    .clk         ( clk_sys ),
    .reset       ( ~pll_core_locked ),
    .gb_mode     ( gb_mode_s ),

    .start       ( gb_start ),
    .busy        ( gbid_busy ),
    .done        ( gbid_done ),

    .cart_req    ( gbid_req ),
    .cart_wr     ( gbid_wr ),
    .cart_addr   ( gbid_addr ),
    .cart_wdata  ( gbid_wdata ),
    .cart_rdata  ( gb_bus_rdata ),
    .cart_done   ( gb_bus_done ),
    .cart_busy   ( gb_bus_busy ),

    .result        ( gbid_result ),
    .title         ( gbid_title ),
    .cgb_flag      ( gbid_cgb_flag ),
    .cart_type     ( gbid_cart_type ),
    .rom_size_code ( gbid_rom_size ),
    .ram_size_code ( gbid_ram_size ),
    .sw_version    ( gbid_sw_version ),
    .checksum_ok   ( gbid_checksum_ok ),
    .raw_bytes     ( gbid_raw_bytes ),
    .checksum_read ( gbid_checksum_read ),
    .checksum_calc ( gbid_checksum_calc )
);

cart_identify_gba identify (
    .clk         ( clk_sys ),
    .reset       ( ~pll_core_locked ),
    .cart_mode   ( gba_mode_s ),

    .start       ( gba_start ),
    .busy        ( id_busy ),
    .done        ( id_done ),

    .cart_req    ( id_req ),
    .cart_wr     ( id_wr ),
    .cart_addr   ( id_addr ),
    .cart_acc    ( id_acc ),
    .cart_wdata  ( id_wdata ),
    .cart_rdata  ( cart_bus_rdata ),
    .cart_done   ( cart_bus_done ),
    .cart_busy   ( cart_bus_busy ),

    .result      ( id_result ),
    .title       ( id_title ),
    .game_code   ( id_game_code ),
    .maker_code  ( id_maker_code ),
    .device_type ( id_device_type ),
    .sw_version  ( id_sw_version ),
    .fixed_ok    ( id_fixed_ok ),
    .checksum_ok ( id_checksum_ok ),
    .reserved_ok ( id_reserved_ok ),

    .raw_words     ( id_raw_words ),
    .checksum_read ( id_checksum_read ),
    .checksum_calc ( id_checksum_calc )
);

// ============================================================
// How big is the GBA cartridge
//
// A GB header says how many banks exist at 0x0148 and cart_dump_gb reads it.
// A GBA header says nothing about its own size, so it has to be measured on
// the bus, and a wrong measurement produces a file that looks perfectly
// normal. gba_size_probe does the measuring; everything about how it decides,
// and what it cannot decide, is in that module's header.
//
// It runs once per identification, immediately after cart_probe has finished
// and only when a GBA cartridge was found. It asks for the connector mode
// itself, because cart_probe has already parked the mode by the time it
// starts.
// ============================================================

wire        sz_done;
wire [31:0] sz_size_bytes;
wire        sz_size_valid;
wire [2:0]  sz_status;
wire [4:0]  sz_points;

// One pulse, on the edge of the probe finishing with a GBA cartridge. Not
// gated on dump_busy: a dump cannot be running here, because a dump cannot
// start until this has produced a size.
assign sz_start = probe_done && (platform == 3'd1);

gba_size_probe sizer (
    .clk        ( clk_sys ),
    .reset      ( ~pll_core_locked ),
    .cart_mode  ( gba_mode_s ),
    .start      ( sz_start ),
    .busy       ( probe_sizing ),
    .done       ( sz_done ),
    .want_gba   ( sz_want_gba ),
    .size_bytes ( sz_size_bytes ),
    .size_valid ( sz_size_valid ),
    .status     ( sz_status ),
    .cart_req   ( sz_req ),
    .cart_wr    ( sz_wr ),
    .cart_addr  ( sz_addr ),
    .cart_acc   ( sz_acc ),
    .cart_wdata ( sz_wdata ),
    .cart_rdata ( cart_bus_rdata ),
    .cart_done  ( cart_bus_done ),
    .cart_busy  ( cart_bus_busy ),
    // The evidence outputs are built and not yet displayed. ui_screen has
    // failed setup three times on its per-column path and none of this can be
    // shown without adding to it, so the size and its status go on screen and
    // the rest waits for a row that can carry them. Unconnected outputs are
    // stripped, so they cost nothing until then; what they would cost, and
    // which to drop first, is in the module header.
    .dbg_class  (  ),
    .dbg_hits   (  ),
    .dbg_words  (  ),
    .dbg_addr   (  ),
    .dbg_base   (  ),
    .dbg_pres   (  ),
    .dbg_points ( sz_points )
);

// ============================================================
// The save type scan. One pass over the ROM after the size probe, looking for
// the string the SDK's save library leaves in the image. It is the only way
// to learn a GBA cartridge's save type that does not write to the cartridge,
// and writing to a GBA cartridge is blocked by the open ST_WRITE abort defect
// in gba_cart_bus. See gba_save_scan.sv.
//
// It costs one full ROM read: about half a second on a 4 MB cartridge and a
// few seconds on a 32 MB one, while the user is already looking at the
// identification screen.
// ============================================================

wire        save_scan_done;
wire        svs_eeprom, svs_sram, svs_sram_f;
wire        svs_flash, svs_flash512, svs_flash1m;
wire        svs_ambiguous, svs_found_any, svs_complete;

// On the edge of the size probe finishing with a size. No size, no scan: the
// scan's loop bound is the ROM size and a zero would scan nothing anyway.
assign save_scan_start = sz_done && sz_size_valid;

// Reset by a new probe, which is a new cartridge and so a result that no
// longer describes anything. A dump is different and used to be a reset here:
// it takes the GBA bus away through the mux above, so a scan underneath it
// must let go, but a reset also cleared the seen bits, which threw away a
// finished scan and made the save button vanish after every ROM dump. So a
// dump aborts instead, which stops a running scan and leaves a finished one
// alone.
gba_save_scan save_scanner (
    .clk            ( clk_sys ),
    .reset          ( ~pll_core_locked | scan_start ),
    .abort          ( dump_busy ),
    .cart_mode      ( gba_mode_s ),
    .start          ( save_scan_start ),
    .rom_size_bytes ( sz_size_bytes ),
    .busy           ( save_scan_busy ),
    .done           ( save_scan_done ),
    .want_gba       ( save_scan_want_gba ),
    .found_eeprom   ( svs_eeprom ),
    .found_sram     ( svs_sram ),
    .found_sram_f   ( svs_sram_f ),
    .found_flash    ( svs_flash ),
    .found_flash512 ( svs_flash512 ),
    .found_flash1m  ( svs_flash1m ),
    .ambiguous      ( svs_ambiguous ),
    .found_any      ( svs_found_any ),
    .complete       ( svs_complete ),
    .bus_req        ( scn_req ),
    .bus_wr         ( scn_wr ),
    .bus_addr       ( scn_addr ),
    .bus_acc        ( scn_acc ),
    .bus_wdata      ( scn_wdata ),
    .bus_rdata      ( cart_bus_rdata ),
    .bus_done       ( cart_bus_done ),
    .bus_busy       ( cart_bus_busy )
);

// A scan result is only meaningful once one has finished for the cartridge
// currently in the slot. Cleared when cart_probe starts, which is what the A
// button does, so a result can never outlive the cartridge it describes. That
// is the same rule the dump result on screen already follows.
// EEPROM needs a second question the scan cannot answer: 512 B or 8 KiB. Ask
// the chip, once, on the edge the scan finishes having found EEPROM. Held off
// an ambiguous cartridge for the same reason the accept condition is: a
// cartridge carrying two families of string is refused, not guessed at.
assign ee_probe_start = save_scan_done && svs_eeprom && !svs_ambiguous;

wire [31:0] ee_size_bytes;
wire [3:0]  ee_addr_bits;
wire        ee_found;

gba_eeprom_probe ee_probe (
    .clk        ( clk_sys ),
    .reset      ( ~pll_core_locked | scan_start ),
    .cart_mode  ( gba_mode_s ),
    .start      ( ee_probe_start ),
    .abort      ( dump_busy ),
    .busy       ( ee_probe_busy ),
    .done       (  ),
    .size_bytes ( ee_size_bytes ),
    .addr_bits  ( ee_addr_bits ),
    .found      ( ee_found ),
    .bus_req    ( ee_req ),
    .bus_wr     ( ee_wr ),
    .bus_addr   ( ee_addr ),
    .bus_acc    ( ee_acc ),
    .bus_wdata  ( ee_wdata ),
    .bus_rdata  ( cart_bus_rdata ),
    .bus_done   ( cart_bus_done ),
    .bus_busy   ( cart_bus_busy )
);

reg save_scan_valid;
always @(posedge clk_sys) begin
    if (~pll_core_locked)        save_scan_valid <= 1'b0;
    else if (scan_start)         save_scan_valid <= 1'b0;
    else if (save_scan_start)    save_scan_valid <= 1'b0;
    else if (save_scan_done)     save_scan_valid <= svs_complete;
end

// What the scan means, decided here rather than in the scanner, which reports
// only what it saw.
//
// What can be read without writing to the cartridge, which is the whole of the
// constraint while the ST_WRITE abort defect is open.
//
//   SRAM_V, SRAM_F_V     32 KiB   plain reads in the save window
//   FLASH_V, FLASH512_V  64 KiB   also plain reads: a Flash chip powers up in
//                                 read array mode and sits in the same window.
//                                 Commands are only needed for chip ID, erase,
//                                 program and bank select, none of which a
//                                 backup does.
//
// Still refused, and each for a write this core may not make:
//
//   FLASH1M_V   its first 64 KiB would read fine, but the second bank needs
//               0xB0 then a bank number written to 0x0E000000. Half a save is
//               worse than none, so the whole thing waits.
// EEPROM_V is accepted now. Reading it does start with writing to it, because
// the block number is clocked in a bit at a time and there is no other way to
// ask for one, but what is written is only ever a read request and
// gba_eeprom_io cannot express a write command. The size the string does not
// give comes from gba_eeprom_probe asking the chip.
//
// A cartridge carrying two families of string is refused rather than guessed
// at, as before.
wire gba_sram_ok   = svs_sram  | svs_sram_f;
wire gba_flash_ok  = svs_flash | svs_flash512;
// The probe having found a chip is part of the condition, not just the string:
// an EEPROM_V cartridge whose chip does not answer either width has no size,
// and a save file of a size nobody established is worse than no save file.
wire gba_eeprom_ok = svs_eeprom && ee_found;
wire gba_save_ok  = save_scan_valid && !svs_ambiguous &&
                    (gba_sram_ok || gba_flash_ok || gba_eeprom_ok);
wire [31:0] gba_save_size = !gba_save_ok  ? 32'd0 :
                            gba_eeprom_ok ? ee_size_bytes :
                            gba_flash_ok  ? 32'd65536 : 32'd32768;

// A GBA cartridge that has a save this core will not read. It drives the same
// screen row a refused GB save does, so nothing new reaches ui_screen, whose
// per-column path has failed setup three times.
wire gba_save_refused = save_scan_valid &&
                        (svs_ambiguous || (svs_found_any && !gba_save_ok));


// The size as a code for the screen, so ui_screen compares four bits in its
// repaint trigger instead of thirty-four, and picks a whole row rather than
// formatting a number in a per-column path. 0 is "nothing to say".
//
//   1..6  1, 2, 4, 8, 16, 32 MB, measured
//   7     32 MB, but by exhaustion rather than observation
//   8     something is there and it could not be sized
//   9     the slot answered with one value everywhere
localparam [2:0] SZ_SIZED    = 3'd1;
localparam [2:0] SZ_CEILING  = 3'd2;
localparam [2:0] SZ_NO_CART  = 3'd3;
localparam [2:0] SZ_CONSTANT = 3'd5;

wire [3:0] gba_size_code =
    (platform != 3'd1)          ? 4'd0 :
    (sz_status == SZ_CEILING)   ? 4'd7 :
    (sz_status == SZ_CONSTANT)  ? 4'd9 :
    (sz_status == SZ_NO_CART)   ? 4'd8 :
    (sz_status != SZ_SIZED)     ? 4'd0 :
    (sz_size_bytes == 32'h00100000) ? 4'd1 :
    (sz_size_bytes == 32'h00200000) ? 4'd2 :
    (sz_size_bytes == 32'h00400000) ? 4'd3 :
    (sz_size_bytes == 32'h00800000) ? 4'd4 :
    (sz_size_bytes == 32'h01000000) ? 4'd5 :
    (sz_size_bytes == 32'h02000000) ? 4'd6 : 4'd8;

// ============================================================
// Dumping
//
// A dump is the one thing this core does that produces something outside
// itself, so it is deliberately hard to start by accident and deliberately
// loud about failing. X only does anything when a cartridge this core knows
// how to read has been identified AND its size is known, which is a different
// sentence on each platform:
//
//   Game Boy   the size is header 0x0148 and the mapper is 0x0147, both read
//              during identification. A dump of an unidentified cartridge
//              would not know how many banks to read or how to reach them.
//
//   GBA        there is no size in the header at all. It is measured on the
//              bus afterwards by gba_size_probe, so X stays inert until that
//              has finished and produced a size it is willing to stand behind.
//              A refusal - an empty slot, or a cartridge that answers with one
//              value everywhere - leaves X doing nothing, which is the right
//              answer: there is no honest number to dump.
//
//
// Y needs no cartridge at all. It writes a 302 byte ramp and is how the byte
// order question gets settled on hardware, which is why it is a first class
// button rather than something hidden behind a build flag.
// ============================================================

wire        dump_done;
wire        dump_failed;
wire [2:0]  dump_err;
wire [15:0] dump_fail_chunk;
wire [15:0] dump_chunks_done;
wire [15:0] dump_chunks_total;
wire [15:0] dump_dbg_reads;
wire [15:0] dump_dbg_struct_reads;
wire [31:0] dump_dbg_last_addr;
wire [31:0] dump_dbg_first_word;
wire [31:0] dump_dbg_flags_word;
wire [31:0] dump_dbg_size_word;
wire [2:0]  dump_probe_err;
wire [1023:0] dump_resp_words;
wire [1023:0] dump_sent_words;

wire [2:0]  dump_used_style;
wire        dump_used_order;
wire [7:0]  dump_tries;
wire        dump_no_open;
wire [1:0]  dump_stall_at;
wire        dump_sum_checked, dump_sum_ok;
wire [15:0] dump_sum_computed, dump_sum_stored;
wire [7:0]  dump_progress;
wire [127:0] dump_out_name;
wire [4:0]   dump_out_name_len;
wire [31:0]  dump_out_ext;
wire [2:0]   dump_out_ext_len;
wire [31:0]  dump_crc32;
wire         dump_save_supported;
wire         dump_save_responded;
wire         dump_save_blank_ff, dump_save_blank_00;
wire [31:0]  dump_save_first;

// P_GB is 3'd2 and P_GBA is 3'd1; see cart_probe.sv. The size probe's own
// busy flag is in here as well as cart_probe's, because on GBA the dump has
// one more thing to wait for than the identification.
// Which system, for the file extension, decided where both facts are already
// known. 0x0143 is 0x80 on a cartridge that runs on both a DMG and a Color
// and 0xC0 on one that needs a Color; both belong to the Game Boy Color set
// and both get .gbc. Everything else on that platform is .gb.
//
// The size cannot stand in for this. A 1 MB Game Boy cartridge and a 1 MB
// GBA cartridge are both ordinary, so a file named only after its length
// tells a reader nothing.
wire [1:0] cart_kind =
    want_save                                                   ? 2'd3 :
    (platform == 3'd1)                                          ? 2'd2 :
    (gbid_cgb_flag == 8'h80 || gbid_cgb_flag == 8'hC0)          ? 2'd1 : 2'd0;

wire dump_ready = id_valid && !cart_engine_busy &&
                  ((platform == 3'd2) ||
                   ((platform == 3'd1) && sz_size_valid));

wire want_rom_dump = key_x_edge && dump_ready && !dump_busy;

// Y only when this cartridge has a save this core can actually read, which is
// a stricter condition than dump_ready and false for most cartridges: GB or
// GBC only, and 8 KB or 2 KB in one bank. dump_engine's save_supported is
// live off the header for exactly this, so the button is absent rather than
// inert. See cart_save_gb for what is refused and why none of it could ever
// be verified against a cartridge on this desk.
// GBA joins it on the one technology that can be read without writing to the
// cartridge. dump_save_supported is live off the GB header; gba_save_ok comes
// from the ROM scan and is false until that scan has finished, so Y is absent
// rather than inert during the scan.
wire save_ready = dump_ready &&
                  (((platform == 3'd2) && dump_save_supported) ||
                   ((platform == 3'd1) && gba_save_ok));

// A cartridge that has a save and is refused anyway. MBC2's RAM lives inside
// the mapper and reports 0x00 at 0x0149, so the type has to be asked as well
// as the size, or the one family whose size byte lies would be the one family
// that got no explanation.
wire gb_has_ram = (gbid_ram_size != 8'd0) ||
                  ((gbid_cart_type >= 8'h05) && (gbid_cart_type <= 8'h06));
wire save_refused = (id_valid && (platform == 3'd2) && gb_has_ram &&
                     !dump_save_supported) || gba_save_refused;
wire want_save  = key_y_edge && save_ready && !dump_busy;

wire dump_start = want_rom_dump | want_save;

// What the screen says. Kept here rather than derived from busy and failed so
// that the result of the last dump stays on the display after it finishes.
//
// It must NOT survive a change of cartridge. Holding it across a scan meant
// dumping one cartridge, swapping to another and pressing A left DUMP
// COMPLETE on screen with the previous cartridge's filename and its checksum
// verdict underneath the new cartridge's title - which reads as though the
// cartridge in the slot had just been dumped and verified. Anyone flipping
// through a stack of cartridges would see it, and it is the one thing on this
// screen a person acts on.
//
// So it clears on the same event that starts a scan, and on the slot itself
// changing. cart_mode_change is cart_play & cart_power, the Pocket's own
// signal, not the connector mode a dump drives, so a dump cannot clear its own
// result partway through.
localparam [1:0] D_IDLE = 2'd0;
localparam [1:0] D_RUN  = 2'd1;
localparam [1:0] D_OK   = 2'd2;
localparam [1:0] D_FAIL = 2'd3;

// Which kind the last dump was, so row 13 shows the right verdict: a ROM has
// the cartridge's own checksum and a save has nothing of the kind. Latched
// with dump_state and cleared with it, so a save's report cannot survive on
// screen under a subsequent ROM dump's filename.
reg dump_was_save;
always @(posedge clk_sys) begin
    if (~pll_core_locked)  dump_was_save <= 1'b0;
    else if (dump_start)   dump_was_save <= want_save;
end

reg [1:0] dump_state;
always @(posedge clk_sys) begin
    if (~pll_core_locked)  dump_state <= D_IDLE;
    else if (dump_start)   dump_state <= D_RUN;
    else if (dump_done)    dump_state <= dump_failed ? D_FAIL : D_OK;
    // After the two above, so a dump starting or finishing on the same cycle
    // as a scan wins. A is gated on ~dump_busy, so that is not reachable
    // today; the ordering is here so it stays unreachable if that changes.
    else if (scan_start || cart_mode_change)
                           dump_state <= D_IDLE;
end

dump_engine dump (
    .clk_sys       ( clk_sys ),
    .reset_sys     ( ~pll_core_locked ),

    .start         ( dump_start ),
    // Simulation hook only. dump_engine's ramp generator is how the
    // testbench exercises the APF path search with no cartridge modelled;
    // tied off here, Quartus folds it and everything it reaches out of the
    // bitstream, which is what removing the Y self test means in hardware.
    .selftest      ( 1'b0 ),
    .save_mode     ( want_save ),
    .byte_order    ( byte_order ),
    .path_style    ( path_style ),
    // dump_path_gen takes fifteen title bytes because that is what a GB
    // header holds at 0x0134. A GBA title is twelve at 0xA0, so it is padded
    // with spaces, which dump_path_gen already treats as padding and trims.
    // The extension is still .gb for both, which is wrong for a GBA dump and
    // is the plan's Phase D, not this change: the title length input that
    // fixes the outstanding GB filename bug is the same change, and doing
    // half of it here would leave two half-fixes.
    .title         ( (platform == 3'd1) ? {id_title, 24'h202020} : gbid_title ),
    .cart_type     ( gbid_cart_type ),
    .rom_size_code ( gbid_rom_size ),
    .ram_size_code ( gbid_ram_size ),
    .platform_gba  ( platform == 3'd1 ),
    .cart_kind     ( cart_kind ),
    .gba_size_bytes( sz_size_bytes ),
    .gba_save_size_bytes( gba_save_size ),
    .gba_save_is_eeprom ( gba_eeprom_ok ),
    .gba_save_addr_bits ( ee_addr_bits ),
    .cart_mode          ( gba_mode_s ),
    .crc32         ( dump_crc32 ),

    .busy          ( dump_busy ),
    .done          ( dump_done ),
    .failed        ( dump_failed ),
    .err           ( dump_err ),
    .fail_chunk    ( dump_fail_chunk ),
    .chunks_done   ( dump_chunks_done ),
    .chunks_total  ( dump_chunks_total ),
    .total_bytes   (  ),

    .dbg_reads        ( dump_dbg_reads ),
    .dbg_struct_reads ( dump_dbg_struct_reads ),
    .dbg_last_addr    ( dump_dbg_last_addr ),
    .dbg_first_word   ( dump_dbg_first_word ),
    .dbg_flags_word   ( dump_dbg_flags_word ),
    .dbg_size_word    ( dump_dbg_size_word ),
    // 0x0190 asks APF what a slot's file is called, which is the only
    // description of the path format that is not a guess. It was on the
    // diagnostics page; with the page gone nothing issues it, and the engine
    // keeps the port because the answer is still the thing to ask for if the
    // path format is ever in question again.
    .probe_start      ( 1'b0 ),
    .probe_slot       ( 16'd0 ),
    .probe_err        ( dump_probe_err ),
    .resp_words       ( dump_resp_words ),
    .sent_words       ( dump_sent_words ),
    .used_style       ( dump_used_style ),
    .used_order       ( dump_used_order ),
    .tries            ( dump_tries ),
    .no_open          ( dump_no_open ),
    .stall_at         ( dump_stall_at ),
    .sum_checked      ( dump_sum_checked ),
    .sum_ok           ( dump_sum_ok ),
    .sum_computed     ( dump_sum_computed ),
    .sum_stored       ( dump_sum_stored ),
    .save_supported   ( dump_save_supported ),
    .save_responded   ( dump_save_responded ),
    .save_blank_ff    ( dump_save_blank_ff ),
    .save_blank_00    ( dump_save_blank_00 ),
    .save_first       ( dump_save_first ),
    .progress         ( dump_progress ),
    .out_name         ( dump_out_name ),
    .out_name_len     ( dump_out_name_len ),
    .out_ext          ( dump_out_ext ),
    .out_ext_len      ( dump_out_ext_len ),

    .want_mode     ( dump_want_mode ),
    .mode_ready    ( cart_mode_ready ),
    .cart_powered  ( cart_mode_s ),

    .bus_req       ( dmp_req ),
    .bus_wr        ( dmp_wr ),
    .bus_addr      ( dmp_addr ),
    .bus_wdata     ( dmp_wdata ),
    .bus_rdata     ( gb_bus_rdata ),
    .bus_done      ( gb_bus_done ),
    .bus_busy      ( gb_bus_busy ),

    .gba_req       ( gdmp_req ),
    .gba_wr        ( gdmp_wr ),
    .gba_addr      ( gdmp_addr ),
    .gba_acc       ( gdmp_acc ),
    .gba_wdata     ( gdmp_wdata ),
    .gba_rdata     ( cart_bus_rdata ),
    .gba_done      ( cart_bus_done ),
    .gba_busy      ( cart_bus_busy ),

    .clk_74a       ( clk_74a ),
    .reset_74a     ( ~pll_core_locked_s ),

    .bridge_addr          ( bridge_addr ),
    .bridge_rd            ( bridge_rd ),
    .bridge_wr            ( bridge_wr ),
    .bridge_wr_data       ( bridge_wr_data ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_rd_data       ( dump_bridge_rd_data ),
    .bridge_rd_hit        ( dump_bridge_rd_hit ),

    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_flush      ( target_dataslot_flush ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err )
);


// cart_play and cart_power are in the clk_74a domain. The diagnostics page
// reports them raw rather than as the AND the bus uses.
wire cart_play_s, cart_power_s;
wire [7:0] cart_adapter_id_s;
synch_3 s_cart_play  (cart_play,  cart_play_s,  clk_sys);
synch_3 s_cart_power (cart_power, cart_power_s, clk_sys);
synch_3 #(.WIDTH(8)) s_cart_adapter (cart_adapter_id[7:0], cart_adapter_id_s, clk_sys);

wire [9:0] tb_addr;
wire [7:0] tb_char;
wire [1:0] tb_attr;
wire       tb_we;

ui_screen screen (
    .clk         ( clk_sys ),
    .reset       ( ~pll_core_locked ),

    .valid       ( id_valid ),
    .platform    ( platform ),
    .title       ( id_title ),
    .game_code   ( id_game_code ),
    .maker_code  ( id_maker_code ),
    .sw_version  ( id_sw_version ),
    .fixed_ok    ( id_fixed_ok ),
    .checksum_ok ( id_checksum_ok ),
    .reserved_ok ( id_reserved_ok ),

    .gba_size_code ( gba_size_code ),
    .crc32         ( dump_crc32 ),

    .gb_title       ( gbid_title ),
    .gb_cart_type   ( gbid_cart_type ),
    .gb_rom_size    ( gbid_rom_size ),
    .gb_ram_size    ( gbid_ram_size ),
    .gb_checksum_ok ( gbid_checksum_ok ),

    .scanning    ( probe_busy ),

    .id_seq          ( id_seq ),

    .dump_state      ( dump_state ),
    .dump_ready      ( dump_ready ),
    .dump_progress   ( dump_progress ),
    .out_name        ( dump_out_name ),
    .out_name_len    ( dump_out_name_len ),
    .out_ext         ( dump_out_ext ),
    .out_ext_len     ( dump_out_ext_len ),
    .dump_err        ( dump_err ),
    .dump_fail_chunk ( dump_fail_chunk ),
    .no_open         ( dump_no_open ),
    .stall_at        ( dump_stall_at ),
    .save_shown      ( dump_was_save ),
    .save_ready      ( save_ready ),
    .save_refused    ( save_refused ),
    .save_responded  ( dump_save_responded ),
    .save_blank_ff   ( dump_save_blank_ff ),
    .save_blank_00   ( dump_save_blank_00 ),
    .save_first      ( dump_save_first ),
    .sum_checked     ( dump_sum_checked ),
    .sum_ok          ( dump_sum_ok ),
    .sum_computed    ( dump_sum_computed ),
    .sum_stored      ( dump_sum_stored ),

    .tb_addr     ( tb_addr ),
    .tb_char     ( tb_char ),
    .tb_attr     ( tb_attr ),
    .tb_we       ( tb_we )
);


// ============================================================
// Video
//
// video_adapter is inherited unchanged: a 240x160 framebuffer written from
// clk_sys and scanned out at clk_vid. The emulator used to fill it; a 30 by
// 20 character text layer fills it now.
// ============================================================

assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;

wire [15:0] pixel_out_addr;
wire [17:0] pixel_out_data;
wire        pixel_out_we;

ui_renderer ui_render (
    .clk        ( clk_sys ),
    .reset      ( ~pll_core_locked ),

    // Near-white on near-black. Deliberately not full white on full black:
    // this is a utility screen that people will read, and it is displayed on
    // a handheld that is often used in the dark.
    .color_fg   ( 18'b111110_111110_111110 ),
    .color_bg   ( 18'b000010_000010_000100 ),

    .tb_addr    ( tb_addr ),
    .tb_char    ( tb_char ),
    .tb_attr    ( tb_attr ),
    .tb_we      ( tb_we ),

    .pixel_addr ( pixel_out_addr ),
    .pixel_data ( pixel_out_data ),
    .pixel_we   ( pixel_out_we )
);

video_adapter video_out (
    .clk_sys    ( clk_sys ),
    .clk_vid    ( clk_vid ),
    .reset      ( ~pll_core_locked ),

    .pixel_addr ( pixel_out_addr ),
    .pixel_data ( pixel_out_data ),
    .pixel_we   ( pixel_out_we ),

    .video_rgb  ( video_rgb ),
    .video_de   ( video_de ),
    .video_vs   ( video_vs ),
    .video_hs   ( video_hs ),
    .video_skip ( video_skip )
);


endmodule
