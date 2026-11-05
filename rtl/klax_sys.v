// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
//============================================================================
// Klax System Wrapper
//
// Encapsulates the 68000 CPU (fx68k), its bus glue (klax_cpu_bus: address
// decode, DTACK timing, read-data mux), and its entire memory map:
//   - Program ROM
//   - Work RAM
//   - Motion object / SLIP RAM
//   - Tilemap RAM (playfield & extended)
//   - Palette RAM
//   - Player 1/2 input ports
//   - OKI MSM6295 ADPCM sound
//   - EEPROM (NVRAM high-score / settings save)
//   - IRQ controller
//   - Watchdog timer
//   - 0x260000 output latch (OKI reset / coin counters / color-RAM bank)
// It also hosts the Motion Object Line-Buffer Renderer.
//
// Exposes the video read ports for the playfield renderer, the motion-object
// line-buffer output, and the sprite ROM fetch port — completely isolating
// the CPU bus routing from the video top level.
//============================================================================

module klax_sys #(
    parameter ENABLE_RAM_BLOCKS = 1,
    parameter CLK_HZ = 20000000     // clk frequency (for OKI sample timing)
) (
    input               clk,
    input               reset,
    input               ce_cpu,      // Clock enable for CPU (7.159 MHz)
    input               vblank,
    input       [8:0]   scanline,
    input       [8:0]   hc,          // native H counter (VRAM-slot DTACK phase)

    // Playfield Renderer Interface (Video Read Ports)
    input       [10:0]  tilemap_rd_addr,
    output      [15:0]  pf_rd_data,
    output      [15:0]  pfx_rd_data,
    // Second playfield-tilemap read port, used by the renderer's tile-graphics
    // prefetch (see klax_playfield.v).
    input       [10:0]  tilemap_pre_addr,
    output      [15:0]  pf_pre_rd_data,

    // Palette Renderer Interface (Video Read Port)
    input       [8:0]   pal_rd_addr,
    output      [15:0]  pal_rd_data,
    input       [8:0]   mob_pal_rd_addr,
    output      [15:0]  mob_pal_rd_data,

    // Motion Object Line-Buffer Display Interface
    input       [8:0]   vid_x,
    input               vid_active,
    output      [8:0]   mo_pix,       // {valid, color[3:0], pen[3:0]}

    // Sprite ROM tile-row fetch port (to DDRAM adapter)
    output              sprow_req,
    output      [11:0]  sprow_code,
    output      [2:0]   sprow_row,
    input       [31:0]  sprow_data,
    input               sprow_ack,

    // IOCTL Download Port (for CPU ROM)
    input               ioctl_download,
    input       [15:0]  ioctl_index,
    input               ioctl_wr,
    input       [26:0]  ioctl_addr,
    input       [7:0]   ioctl_dout,

    // EEPROM NVRAM save support
    input       [10:0]  eeprom_up_addr,
    output      [7:0]   eeprom_up_data,
    output              eeprom_cpu_wr,

    // Active-high control inputs. klax_inputs converts these to the
    // original active-low P1/P2 port bits.
    input               p1_coin1,
    input               p1_coin2,
    input               p1_button1,
    input               p1_right,
    input               p1_left,
    input               p1_down,
    input               p1_up,
    input               p2_button1,
    input               p2_right,
    input               p2_left,
    input               p2_down,
    input               p2_up,
    input               service,

    // Mono signed audio from the OKI MSM6295 model.
    output      [15:0]  audio_sample,

    // CPU bus state and per-subsystem activity flags, exported as observation
    // points for simulation. The MiSTer top leaves them unread, so synthesis
    // prunes whatever only feeds them.
    output      [23:0]  dbg_cpu_addr,
    output      [15:0]  dbg_cpu_data_in,
    output      [15:0]  dbg_cpu_data_out,
    output      [2:0]   dbg_cpu_fc,
    output              dbg_cpu_as_n,
    output              dbg_cpu_uds_n,
    output              dbg_cpu_lds_n,
    output              dbg_cpu_rw_n,
    output              dbg_cpu_dtack_n,
    output              dbg_cpu_reset,
    output      [2:0]   dbg_cpu_ipl_n,
    output      [15:0]  dbg_vram_flags,
    output      [15:0]  dbg_mob_flags,
    output      [15:0]  dbg_mo_flags        // klax_motion_objects debug
);

    // === CPU Signals ===
    wire [23:0] cpu_addr;
    wire [15:0] cpu_data_out;
    wire [15:0] cpu_data_in;
    wire [2:0]  cpu_fc;
    wire        cpu_as_n;
    wire        cpu_uds_n;
    wire        cpu_lds_n;
    wire        cpu_rw_n;
    wire        cpu_dtack_n;

    // === Memory Data Buses ===
    wire [15:0] rom_data;
    wire [15:0] work_ram_data;
    wire [15:0] slip_ram_data;
    wire [15:0] mob_ram_data;
    wire [15:0] pf_ram_data;
    wire [15:0] pfx_ram_data;
    wire [15:0] pal_cpu_data;
    wire [15:0] eeprom_data;
    wire [15:0] input_p1_data;
    wire [15:0] input_p2_data;
    wire [7:0]  oki_data;

    // === CPU Bus Boundary ===
    wire cs_rom, cs_eeprom, cs_eeprom_unlock, cs_input_p1, cs_input_p2;
    wire cs_oki, cs_watchdog, cs_irq_ack, cs_palette;
    wire cs_playfield, cs_slip, cs_pf_ext, cs_mob, cs_work_ram;
    wire cpu_lane_active = ~cpu_uds_n || ~cpu_lds_n;
    wire cpu_wr_en = ~cpu_rw_n & ~cpu_as_n & cpu_lane_active;
    wire [2:0] cpu_ipl_n;
    wire cpu_bus_ack = ~cpu_as_n & ~cpu_dtack_n;
    wire cpu_bus_read = cpu_bus_ack & cpu_rw_n;
    wire cpu_bus_write = cpu_bus_ack & ~cpu_rw_n;
    wire cpu_write_selected_nonzero =
        (~cpu_uds_n && (cpu_data_out[15:8] != 8'd0)) ||
        (~cpu_lds_n && (cpu_data_out[7:0] != 8'd0));

    // === Watchdog Timer ===
    // Main-board watchdog: resets the CPU subsystem if the program stops
    // petting it (a write to 0x2E0000). See klax_watchdog.v for the silicon
    // reference and the note on MAME leaving its watchdog disabled. wdog_reset
    // folds into the CPU, bus, and IRQ resets via sys_reset; the watchdog
    // counter itself keys off the external reset only, so it free-runs and
    // self-releases. The video RAM and renderers stay on the external reset,
    // so a watchdog bite never disturbs an in-progress frame -- only the CPU
    // restarts, exactly as on the PCB.
    wire wdog_reset;
    wire sys_reset = reset | wdog_reset;

    klax_watchdog u_watchdog (
        .clk        (clk),
        .reset      (reset),
        .vblank     (vblank),
        .pet        (cpu_wr_en && cs_watchdog),
        .wdog_reset (wdog_reset)
    );

    // 68000 interrupt acknowledge: CPU-space cycle (FC=7) with AS asserted.
    // VPA = NAND(BAS,FC2,FC1,FC0) on the board (F20 @9B), so the CPU
    // autovectors; klax_cpu_bus suppresses DTACK for these cycles.
    wire cpu_iack_cycle = ~cpu_as_n && (cpu_fc == 3'b111);

    // Sticky per-subsystem activity flags for the dbg_vram_flags observation
    // port (see the header note on the dbg_* outputs).
    reg dbg_pf_wr_seen = 1'b0;
    reg dbg_pfx_wr_seen = 1'b0;
    reg dbg_pf_wr_nonzero_seen = 1'b0;
    reg dbg_pfx_wr_nonzero_seen = 1'b0;
    reg dbg_pf_hi_wr_seen = 1'b0;
    reg dbg_pf_lo_wr_seen = 1'b0;
    reg dbg_pfx_hi_wr_seen = 1'b0;
    reg dbg_pfx_lo_wr_seen = 1'b0;
    reg dbg_pf_cpu_rd_seen = 1'b0;
    reg dbg_pfx_cpu_rd_seen = 1'b0;
    reg dbg_pf_cpu_rd_nonzero_seen = 1'b0;
    reg dbg_pfx_cpu_rd_nonzero_seen = 1'b0;
    reg dbg_pf_video_nonzero_seen = 1'b0;
    reg dbg_pfx_video_nonzero_seen = 1'b0;
    reg dbg_tilemap_video_addr_seen = 1'b0;

    assign dbg_vram_flags = {
        1'b1,
        dbg_tilemap_video_addr_seen,
        dbg_pfx_video_nonzero_seen,
        dbg_pf_video_nonzero_seen,
        dbg_pfx_cpu_rd_nonzero_seen,
        dbg_pf_cpu_rd_nonzero_seen,
        dbg_pfx_cpu_rd_seen,
        dbg_pf_cpu_rd_seen,
        dbg_pfx_lo_wr_seen,
        dbg_pfx_hi_wr_seen,
        dbg_pf_lo_wr_seen,
        dbg_pf_hi_wr_seen,
        dbg_pfx_wr_nonzero_seen,
        dbg_pf_wr_nonzero_seen,
        dbg_pfx_wr_seen,
        dbg_pf_wr_seen
    };

    klax_cpu_bus u_bus (
        .clk              (clk),
        .reset            (sys_reset),
        .ce_cpu           (ce_cpu),
        .hc               (hc),
        .vblank           (vblank),
        .cpu_addr         (cpu_addr[23:0]),
        .cpu_as_n         (cpu_as_n),
        .cpu_rw_n         (cpu_rw_n),
        .cpu_uds_n        (cpu_uds_n),
        .cpu_lds_n        (cpu_lds_n),
        .cpu_iack         (cpu_iack_cycle),
        .cpu_dtack_n      (cpu_dtack_n),
        .cpu_data_in      (cpu_data_in),
        .rom_data         (rom_data),
        .work_ram_data    (work_ram_data),
        .slip_ram_data    (slip_ram_data),
        .mob_ram_data     (mob_ram_data),
        .pf_ram_data      (pf_ram_data),
        .pfx_ram_data     (pfx_ram_data),
        .pal_cpu_data     (pal_cpu_data),
        .eeprom_data      (eeprom_data),
        .input_p1_data    (input_p1_data),
        .input_p2_data    (input_p2_data),
        .oki_data         (oki_data),
        .cs_rom           (cs_rom),
        .cs_eeprom        (cs_eeprom),
        .cs_eeprom_unlock (cs_eeprom_unlock),
        .cs_input_p1      (cs_input_p1),
        .cs_input_p2      (cs_input_p2),
        .cs_oki           (cs_oki),
        .cs_watchdog      (cs_watchdog),
        .cs_irq_ack       (cs_irq_ack),
        .cs_palette       (cs_palette),
        .cs_playfield     (cs_playfield),
        .cs_slip          (cs_slip),
        .cs_pf_ext        (cs_pf_ext),
        .cs_mob           (cs_mob),
        .cs_work_ram      (cs_work_ram)
    );

    // === Input Ports ===
    klax_inputs u_inputs (
        .vblank     (vblank),
        .p1_coin1   (p1_coin1),
        .p1_coin2   (p1_coin2),
        .p1_button1 (p1_button1),
        .p1_right   (p1_right),
        .p1_left    (p1_left),
        .p1_down    (p1_down),
        .p1_up      (p1_up),
        .p2_button1 (p2_button1),
        .p2_right   (p2_right),
        .p2_left    (p2_left),
        .p2_down    (p2_down),
        .p2_up      (p2_up),
        .service    (service),
        .p1_data    (input_p1_data),
        .p2_data    (input_p2_data)
    );

    // === Output Latch (0x260000 write) ===
    // Documented in the Klax manual memory map (Figure 5-2, "LATCH"). All bits
    // sit on the high data byte D[15:8] and RESET clears the latch:
    //   D8  ADPCM (OKI) chip reset, active low   D9   spare
    //   D10 coin counter 2 (right)               D11  coin counter 1 (left)
    //   D12 spare                                D13  color-RAM bank select
    // MAME models the write as a no-op (klax.cpp latch_w() is empty). A MAME
    // trace of a full boot+attract+demo run shows the
    // game only ever drives D8 -- written 0 then 1 once at boot (pc 0x005c7c/94,
    // ~frame 6) and never touched again; D13 is never set and the coin counters
    // only click an external mechanical meter. So the no-op is functionally
    // harmless. We still model the latch and route the one functional bit (D8)
    // to the OKI reset, so the OKI is held in reset from power-on until the CPU
    // releases it -- silicon-faithful, matching the manual's "RESET clears this
    // latch" plus the active-low ADPCM reset. The write already lands in
    // cs_input_p1 (0x260000 R/W share one decode), which is in cs_any, so DTACK
    // is unaffected; this block only snoops the high-byte write strobe.
    //
    // Silicon notes (schematic Sheet 2): the latch is an LS174 at 2A clocked
    // by /LATCH = R//W | /PAR — i.e. ANY write anywhere in the 0x26 page
    // (P1 and P2 word addresses alike) clocks it, so the strobe below covers
    // cs_input_p1 and cs_input_p2. Its /CLR is /SYSRES, which includes a
    // watchdog bite, hence sys_reset here. The UDS qualifier is kept for data
    // validity: hardware would latch whatever floats on D13..D8 during a
    // lower-byte-only write, which the game never issues and which has no
    // meaningful model. D13 = CBANK, the color-RAM bank select (color RAM
    // A9, Sheet 8) — routed to the palette below; the game never sets it.
    reg [13:8] klax_latch;
    wire latch_wr = cpu_wr_en && (cs_input_p1 || cs_input_p2) && ~cpu_uds_n;
    always @(posedge clk or posedge sys_reset) begin
        if (sys_reset)
            klax_latch <= 6'd0;                 // /SYSRES clears the latch
        else if (latch_wr)
            klax_latch <= cpu_data_out[13:8];
    end

    wire oki_reset_n = klax_latch[8];           // D8: ADPCM reset, active low
    wire cbank = klax_latch[13];                // D13: color-RAM bank select
    // D10/D11 coin counters drive only an external mechanical meter; D9 is
    // /AUDRES for the unstuffed AUX audio board; D12 is spare. Latched for
    // faithfulness, unrouted. Reference them so lint tools don't flag them.
    wire unused_latch = &{1'b0, klax_latch[12], klax_latch[11],
                          klax_latch[10], klax_latch[9]};

    // === OKI MSM6295 ADPCM Sound ===
    // u_oki is the chip (bit-exact vs MAME); u_audio_filter is the board's
    // analog output stage around it (Sheet 4). Keeping them separate keeps
    // the chip model pure and independently verifiable against MAME.
    wire [15:0] oki_audio_raw;
    wire        oki_clk_en;

    klax_oki6295 #(
        .CLK_HZ(CLK_HZ)
    ) u_oki (
        .clk            (clk),
        .reset          (reset | ~oki_reset_n),
        .rd_en          (cpu_bus_read && cs_oki),
        .wr_en          (cpu_bus_write && cs_oki && !cpu_lds_n),
        .wr_data        (cpu_data_out[7:0]),
        .rd_data        (oki_data),
        .ioctl_download (ioctl_download),
        .ioctl_index    (ioctl_index),
        .ioctl_wr       (ioctl_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .audio_sample   (oki_audio_raw),
        .oki_clk_en     (oki_clk_en),
        .debug_flags    ()
    );

    // === Analog output filter (LM324 18C sections, Sheet 4) ===
    // 5-pole low-pass between the DAC pin and the speaker: -3 dB at 790 Hz,
    // -49.6 dB at the 6779.4 Hz first image. Held in reset with the chip so
    // a D8 (ADPCM reset) release starts both from a clean state.
    klax_audio_filter u_audio_filter (
        .clk        (clk),
        .reset      (reset | ~oki_reset_n),
        .oki_clk_en (oki_clk_en),
        .sample_in  (oki_audio_raw),
        .sample_out (audio_sample)
    );

    // === EEPROM ===
    // sys_reset: the write-unlock latch (LS74 @5K) is cleared by /SYSRES on
    // the PCB, so a watchdog bite re-locks it. EEPROM contents are unaffected.
    klax_eeprom u_eeprom (
        .clk        (clk),
        .reset      (sys_reset),
        .addr       (cpu_addr[11:1]),
        .rd_data    (eeprom_data),
        .wr_data    (cpu_data_out),
        .wr_en      (cpu_wr_en && cs_eeprom),
        .lds_n      (cpu_lds_n),
        .unlock_wr  (cpu_wr_en && cs_eeprom_unlock),
        .ioctl_wr   (ioctl_download && ioctl_wr && (ioctl_index == 16'd2)),
        .ioctl_addr (ioctl_addr[10:0]),
        .ioctl_dout (ioctl_dout),
        .up_addr    (eeprom_up_addr),
        .up_data    (eeprom_up_data),
        .cpu_wr_done(eeprom_cpu_wr)
    );

    // === Interrupts ===
    klax_irq u_irq (
        .clk        (clk),
        .reset      (sys_reset),
        .vblank     (vblank),
        .scanline   (scanline),
        .irq_ack_wr (cpu_wr_en && cs_irq_ack),
        .ipl_n      (cpu_ipl_n)
    );

    // === 68000 CPU (fx68k, cycle-exact) ===
    // The board 68000 runs at the native pixel clock: ce_cpu marks each
    // CPU clock rising edge, and klax_cpu68k derives the falling-edge enable.

    assign dbg_cpu_addr      = cpu_addr[23:0];
    assign dbg_cpu_data_in   = cpu_data_in;
    assign dbg_cpu_data_out  = cpu_data_out;
    assign dbg_cpu_fc        = cpu_fc;
    assign dbg_cpu_as_n      = cpu_as_n;
    assign dbg_cpu_uds_n     = cpu_uds_n;
    assign dbg_cpu_lds_n     = cpu_lds_n;
    assign dbg_cpu_rw_n      = cpu_rw_n;
    assign dbg_cpu_dtack_n   = cpu_dtack_n;
    // This tap reports the external reset only. The watchdog still resets the
    // real CPU (CPU/bus/irq via sys_reset); keeping the exported signal
    // external-only lets monotonic "seen" latches in a simulation survive a
    // watchdog bite from a CPU model that does not pet every frame.
    assign dbg_cpu_reset     = reset;
    assign dbg_cpu_ipl_n     = cpu_ipl_n;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            dbg_pf_wr_seen <= 1'b0;
            dbg_pfx_wr_seen <= 1'b0;
            dbg_pf_wr_nonzero_seen <= 1'b0;
            dbg_pfx_wr_nonzero_seen <= 1'b0;
            dbg_pf_hi_wr_seen <= 1'b0;
            dbg_pf_lo_wr_seen <= 1'b0;
            dbg_pfx_hi_wr_seen <= 1'b0;
            dbg_pfx_lo_wr_seen <= 1'b0;
            dbg_pf_cpu_rd_seen <= 1'b0;
            dbg_pfx_cpu_rd_seen <= 1'b0;
            dbg_pf_cpu_rd_nonzero_seen <= 1'b0;
            dbg_pfx_cpu_rd_nonzero_seen <= 1'b0;
            dbg_pf_video_nonzero_seen <= 1'b0;
            dbg_pfx_video_nonzero_seen <= 1'b0;
            dbg_tilemap_video_addr_seen <= 1'b0;
        end else begin
            if (tilemap_rd_addr != 11'd0)
                dbg_tilemap_video_addr_seen <= 1'b1;
            if (pf_rd_data != 16'd0)
                dbg_pf_video_nonzero_seen <= 1'b1;
            if (pfx_rd_data != 16'd0)
                dbg_pfx_video_nonzero_seen <= 1'b1;

            if (cpu_bus_write && cs_playfield) begin
                dbg_pf_wr_seen <= 1'b1;
                if (!cpu_uds_n)
                    dbg_pf_hi_wr_seen <= 1'b1;
                if (!cpu_lds_n)
                    dbg_pf_lo_wr_seen <= 1'b1;
                if (cpu_write_selected_nonzero)
                    dbg_pf_wr_nonzero_seen <= 1'b1;
            end

            if (cpu_bus_write && cs_pf_ext) begin
                dbg_pfx_wr_seen <= 1'b1;
                if (!cpu_uds_n)
                    dbg_pfx_hi_wr_seen <= 1'b1;
                if (!cpu_lds_n)
                    dbg_pfx_lo_wr_seen <= 1'b1;
                if (cpu_write_selected_nonzero)
                    dbg_pfx_wr_nonzero_seen <= 1'b1;
            end

            if (cpu_bus_read && cs_playfield) begin
                dbg_pf_cpu_rd_seen <= 1'b1;
                if (cpu_data_in != 16'd0)
                    dbg_pf_cpu_rd_nonzero_seen <= 1'b1;
            end

            if (cpu_bus_read && cs_pf_ext) begin
                dbg_pfx_cpu_rd_seen <= 1'b1;
                if (cpu_data_in != 16'd0)
                    dbg_pfx_cpu_rd_nonzero_seen <= 1'b1;
            end
        end
    end

    klax_cpu68k u_cpu (
        .clk      (clk),
        .reset    (sys_reset),     // includes the watchdog bite
        .ce_cpu   (ce_cpu),
        .ipl_n    (cpu_ipl_n),
        .dtack_n  (cpu_dtack_n),
        .vpa_n    (~cpu_iack_cycle),
        .data_in  (cpu_data_in),
        .addr     (cpu_addr),
        .data_out (cpu_data_out),
        .fc       (cpu_fc),
        .as_n     (cpu_as_n),
        .uds_n    (cpu_uds_n),
        .lds_n    (cpu_lds_n),
        .rw_n     (cpu_rw_n)
    );

    // === Memory Components ===

    // 1. Program ROM (256KB)
    klax_prog_rom u_prog_rom (
        .clk            (clk),
        .addr           (cpu_addr[17:1]), // A17..A1 for 128K 16-bit words
        .data           (rom_data),
        .ioctl_download (ioctl_download),
        .ioctl_wr       (ioctl_wr && (ioctl_index == 0)),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout)
    );

    generate
        if (ENABLE_RAM_BLOCKS != 0) begin : gen_ram_blocks
            wire [5:0]  mo_slip_rd_addr;
            wire [15:0] mo_slip_rd_data;
            wire [9:0]  mo_mob_rd_addr;
            wire [15:0] mo_mob_rd_data;

            // 2. Work RAM (6 KB region in the 0x3F2800-0x3F3FFF window).
            klax_work_ram u_work_ram (
                .clk      (clk),
                .addr     (cpu_addr[12:1]), // A12..A1 for 4K words
                .rd_data  (work_ram_data),
                .wr_data  (cpu_data_out),
                .wr_en    (cpu_wr_en && cs_work_ram),
                .uds_n    (cpu_uds_n),
                .lds_n    (cpu_lds_n)
            );

            // 3. Motion Object RAM + SLIP RAM
            klax_mob_ram u_mob_ram (
                .clk                 (clk),
                .reset               (reset),
                .slip_cpu_addr       (cpu_addr[6:1]),
                .slip_cpu_rd_data    (slip_ram_data),
                .slip_wr_data        (cpu_data_out),
                .slip_wr_en          (cpu_wr_en && cs_slip),
                .slip_uds_n          (cpu_uds_n),
                .slip_lds_n          (cpu_lds_n),
                .slip_cpu_rd_en      (cpu_bus_read && cs_slip),
                .mob_cpu_addr        (cpu_addr[10:1]),
                .mob_cpu_rd_data     (mob_ram_data),
                .mob_wr_data         (cpu_data_out),
                .mob_wr_en           (cpu_wr_en && cs_mob),
                .mob_uds_n           (cpu_uds_n),
                .mob_lds_n           (cpu_lds_n),
                .mob_cpu_rd_en       (cpu_bus_read && cs_mob),
                .slip_rd_addr        (mo_slip_rd_addr),
                .slip_rd_data        (mo_slip_rd_data),
                .mob_rd_addr         (mo_mob_rd_addr),
                .mob_rd_data         (mo_mob_rd_data),
                .debug_flags         (dbg_mob_flags)
            );

            // 4. Motion Object Line-Buffer Renderer
            klax_motion_objects u_motion_objects (
                .clk            (clk),
                .reset          (reset),
                .scanline       (scanline),
                .vblank         (vblank),
                .vid_x          (vid_x),
                .vid_active     (vid_active),
                .mo_pix         (mo_pix),
                .slip_rd_addr   (mo_slip_rd_addr),
                .slip_rd_data   (mo_slip_rd_data),
                .mob_rd_addr    (mo_mob_rd_addr),
                .mob_rd_data    (mo_mob_rd_data),
                .sprow_req      (sprow_req),
                .sprow_code     (sprow_code),
                .sprow_row      (sprow_row),
                .sprow_data     (sprow_data),
                .sprow_ack      (sprow_ack),
                .debug_flags    (dbg_mo_flags)
            );

            // 5. Tilemap RAM (Playfield + Extended)
            // CPU addresses: 0x3F0000 - 0x3F0F7F (Playfield, 2K words)
            //                0x3F1000 - 0x3F1FFF (Extended, 2K words)
            klax_tilemap_ram u_tilemap_ram (
                .clk          (clk),
                .rd_addr      (tilemap_rd_addr),
                .pf_rd_data   (pf_rd_data),
                .pfx_rd_data  (pfx_rd_data),
                .pre_addr     (tilemap_pre_addr),
                .pf_pre_rd_data (pf_pre_rd_data),

                .cpu_addr     (cpu_addr[11:1]),
                .pf_cpu_rd_data (pf_ram_data),
                .pf_wr_data   (cpu_data_out),
                .pf_wr_en     (cpu_wr_en && cs_playfield),
                .pf_uds_n     (cpu_uds_n),
                .pf_lds_n     (cpu_lds_n),

                .pfx_cpu_rd_data(pfx_ram_data),
                .pfx_wr_data  (cpu_data_out),
                .pfx_wr_en    (cpu_wr_en && cs_pf_ext),
                .pfx_uds_n    (cpu_uds_n),
                .pfx_lds_n    (cpu_lds_n)
            );

            // 6. Palette RAM (color RAM: 2 banks x 512 IRGB_1555 entries;
            //    CBANK = output-latch D13 is color-RAM address bit A9 on the
            //    PCB, switching both CPU access and display. Byte-wide on the
            //    upper 68000 data lane.)
            klax_palette u_palette (
                .clk      (clk),
                .cbank    (cbank),
                .rd_addr  (pal_rd_addr),
                .rd_data  (pal_rd_data),
                .mob_rd_addr(mob_pal_rd_addr),
                .mob_rd_data(mob_pal_rd_data),

                .cpu_addr (cpu_addr[10:1]),
                .cpu_rd_data(pal_cpu_data),
                .wr_data  (cpu_data_out),
                .wr_en    (cpu_wr_en && cs_palette),
                .uds_n    (cpu_uds_n),
                .lds_n    (cpu_lds_n)
            );
        end else begin : gen_no_ram_blocks
            assign work_ram_data = 16'hFFFF;
            assign slip_ram_data = 16'hFFFF;
            assign mob_ram_data  = 16'hFFFF;
            assign pf_ram_data   = 16'hFFFF;
            assign pfx_ram_data  = 16'hFFFF;
            assign pal_cpu_data  = 16'hFFFF;
            assign pf_rd_data    = 16'h0000;
            assign pfx_rd_data   = 16'h0000;
            assign pf_pre_rd_data = 16'h0000;
            assign pal_rd_data   = 16'h0000;
            assign mob_pal_rd_data = 16'h0000;
            assign dbg_mob_flags = 16'd0;
            assign dbg_mo_flags  = 16'd0;
            assign mo_pix        = 9'd0;
            assign sprow_req     = 1'b0;
            assign sprow_code    = 12'd0;
            assign sprow_row     = 3'd0;
        end
    endgenerate

endmodule
