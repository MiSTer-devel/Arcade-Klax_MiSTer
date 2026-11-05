// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
//============================================================================
// Klax CPU Bus Glue — silicon ground truth
//
// Owns the 68000 address decode boundary:
//   - chip selects from the dumped 11C decode GAL (klax_addr_decode)
//   - DTACK generation modeled on the real wait-state hardware
//   - CPU read-data mux (open bus = 0xFFFF, data-bus pull-ups)
//
// DTACK (schematic Sheet 2): every bus cycle COMPLETES on real hardware —
// there is no such thing as a stalling unmapped access. The LS163A at 10B
// (clock RCLOCK = the 7.16 MHz pixel/CPU clock, sync-cleared while BAS is
// idle) loads {D,C,B,A} = {+5V, PVCPU|/VRAM, /PCM, /EEPROM} once per cycle
// (LD/ENP self-sequenced from QD) and counts to 15; RCO -> DTACK -> /DTACK.
//   default (ROM/PAR/WDOG/VACK/AUX/ROM2/unmapped): load 15 -> 0 wait states
//   EEPROM:      load 14 -> +1 RCLOCK
//   OKI (/PCM):  load 13 -> +2 RCLOCK
//   VRAM/palette (/VRAM): load {1,PVCPU,1,1} -> 0 waits when the CPU's video
//     RAM time slot is up next, else +4 RCLOCK (one VAS slot rotation).
//
// PVCPU comes from the VRAM arbitration state machine: the dumped 9W GAL
// (136075-1003 "MOBL2", registered at 14.318 MHz) generates the pre-VAS slot
// code from the H-counter phase; PVCPU = PVAS0 & PVAS1 & VREQ (LS11 @10U),
// VREQ = NOR(DTACK, /VRAM) (LS02 @9L). The 9W equations are transcribed
// verbatim below; during display lines they reserve hcnt%8 == 5,6 for the
// two playfield tilemap fetches of each 8px tile and grant every other phase
// to the CPU on demand.
//
// Interrupt acknowledge: VPA = NAND(BAS,FC2,FC1,FC0) (F20 @9B) asserts
// combinationally during an IACK cycle, while DTACK needs at least one
// RCLOCK edge — VPA always wins the race and the 68000 autovectors. The
// decode DOES fire during IACK (the all-ones IACK address mirrors into the
// /VRAM window), so DTACK is explicitly suppressed here to model that
// resolved race; klax_sys drives the CPU's VPA.
//
// Open bus: unselected reads (and the write-only regions) fall through to
// 0xFFFF and still complete. MAME differs on both counts (no wait states,
// unmapped reads return 0) — silicon over MAME.
//============================================================================

module klax_cpu_bus (
    input               clk,
    input               reset,
    input               ce_cpu,      // RCLOCK cadence (1-of-8 clk at native)

    // video phase for the VRAM arbitration replica
    input       [8:0]   hc,          // native H counter (0 = first visible)
    input               vblank,

    input       [23:0]  cpu_addr,
    input               cpu_as_n,
    input               cpu_rw_n,
    input               cpu_uds_n,
    input               cpu_lds_n,
    input               cpu_iack,    // FC=7 & AS: autovector cycle (VPA wins)
    output              cpu_dtack_n,
    output      [15:0]  cpu_data_in,

    input       [15:0]  rom_data,
    input       [15:0]  work_ram_data,
    input       [15:0]  slip_ram_data,
    input       [15:0]  mob_ram_data,
    input       [15:0]  pf_ram_data,
    input       [15:0]  pfx_ram_data,
    input       [15:0]  pal_cpu_data,
    input       [15:0]  eeprom_data,
    input       [15:0]  input_p1_data,
    input       [15:0]  input_p2_data,
    input       [7:0]   oki_data,

    output              cs_rom,
    output              cs_eeprom,
    output              cs_eeprom_unlock,
    output              cs_input_p1,
    output              cs_input_p2,
    output              cs_oki,
    output              cs_watchdog,
    output              cs_irq_ack,
    output              cs_palette,
    output              cs_playfield,
    output              cs_slip,
    output              cs_pf_ext,
    output              cs_mob,
    output              cs_work_ram
);

    wire cs_vram_window;

    klax_addr_decode u_decode (
        .cpu_addr         (cpu_addr),
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
        .cs_work_ram      (cs_work_ram),
        .cs_vram_window   (cs_vram_window)
    );

    //------------------------------------------------------------------------
    // VRAM arbitration replica: 9W GAL (MOBL2) + LS11 PVCPU
    //
    // The GAL registers clock at 14.318 MHz = two ticks per pixel; RCLOCKB
    // (i6) distinguishes the halves. The sub-pixel phase is reconstructed
    // from ce_cpu (RCLOCK cadence): tick0 at the pixel boundary, tick1 at
    // the half-pixel point 4 clk later (with ce_cpu tied high both ticks
    // collapse to every clk, which only shifts wait timing).
    //
    // Input mapping (schematic Sheet 5 + the 6W dump for the markers):
    //   i2=VREQ  i3/i4/i5=1H/2H/4H (SOS hcnt bits = (hc+12) mod 8)
    //   i6=RCLOCKB  i7=HBLANK (hc>=336)  i8=NXL^NXLDL line-boundary marker
    //   i9=/PFHST (low hc 430..445, from the dumped 6W /PFHST equation)
    //   i12=/VBLNRES (= NOT VBLANK, LS04 on Sheet 6)
    //------------------------------------------------------------------------
    reg [2:0] subphase;
    always @(posedge clk or posedge reset) begin
        if (reset)
            subphase <= 3'd0;
        else if (ce_cpu)
            subphase <= 3'd1;
        else
            subphase <= subphase + 3'd1;
    end
    wire tick0 = ce_cpu;                // first 14.3 MHz edge of the pixel
    wire tick1 = (subphase == 3'd4);    // second (RCLOCKB) edge

    wire [2:0] hphase = hc[2:0] + 3'd4; // SOS hcnt low bits ((hc+12) mod 8)
    wire w1h = hphase[0];
    wire w2h = hphase[1];
    wire w4h = hphase[2];
    wire hbl = (hc >= 9'd336);
    wire pfhst_n = ~((hc >= 9'd430) && (hc <= 9'd445));
    wire vblnres_n = ~vblank;
    // NXL^NXLDL straddles the line wrap; per-tick windows at 14.3 MHz grain.
    wire nxlmark_t0 = (hc == 9'd443) || (hc == 9'd444);
    wire nxlmark_t1 = (hc == 9'd442) || (hc == 9'd443);

    // Registered 9W feedbacks (pin levels; pin = NOT of the registered SOP).
    reg rf14, rf15, rf16, rf19;

    // VREQ = NOR(DTACK, /VRAM): pending CPU request for the video RAM.
    wire dtack_int;
    wire vreq = ~cpu_as_n && cs_vram_window && ~dtack_int && ~cpu_iack;

    // One 9W register step (i6 = RCLOCKB, i8 = line marker for that tick).
    // Equations verbatim from jedutil on 136075-1003.9w.bin. Returns the
    // next {rf14,rf15,rf16,rf19} pin levels (pin = NOT of registered SOP).
    function [3:0] next_9w;
        input i6, i8;
        input r14, r15, r16, r19;
        input f1h, f2h, f4h, fhbl, fpfhst_n, fvblnres_n, fvreq;
        reg t14, t15, t16, t19;
        begin
            t14 = ~( (~i6 & ~fvblnres_n & r14 & r16) |
                     (~i6 &  fhbl       & r14 & r16) |
                     ( fpfhst_n & ~r14) |
                     ( i6       & ~r14) );
            t15 = ~( (~f1h & ~f2h & f4h & ~i6 & fpfhst_n & fvblnres_n) |
                     (~i6 & fhbl & fvblnres_n & r15 & r16) |
                     ( fpfhst_n & ~r15) |
                     ( i6       & ~r15) );
            t16 = ~( (~i6 & fhbl) | (i6 & ~r16) );
            t19 = ~( (fvreq & ~f1h & i6) |
                     (fvreq & ~f2h & i6) |
                     (fvreq & ~f4h & i6) |
                     (fvreq &  i6  & ~i8) |
                     (~f1h &  f2h & ~f4h & i6 & r15) |
                     (~f1h &  f2h &  f4h & i6 & r14) |
                     ( f1h & ~f2h &  f4h & i6 & r14) |
                     (~i6 & ~r19) );
            next_9w = {t14, t15, t16, t19};
        end
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            {rf14, rf15, rf16, rf19} <= 4'b1111;
        end else if (tick0) begin
            {rf14, rf15, rf16, rf19} <= next_9w(1'b0, nxlmark_t0,
                rf14, rf15, rf16, rf19,
                w1h, w2h, w4h, hbl, pfhst_n, vblnres_n, vreq);
        end else if (tick1) begin
            {rf14, rf15, rf16, rf19} <= next_9w(1'b1, nxlmark_t1,
                rf14, rf15, rf16, rf19,
                w1h, w2h, w4h, hbl, pfhst_n, vblnres_n, vreq);
        end
    end

    // Combinational PVAS outputs (o13/o18) at the RCLOCK sample point
    // (tick0 inputs: i6=0, i8=nxlmark_t0) and PVCPU (LS11 @10U).
    wire pvas0 = ~( ( w1h &  w2h &  w4h & nxlmark_t0) |
                    (~w1h &  w2h & ~w4h & rf15) |
                    (~w1h &  w2h &  w4h & rf14) |
                    ( w1h & ~w2h &  w4h & rf14) );
    wire pvas1 = ~( (~w1h & rf19) | (~w2h & rf19) |
                    (~w4h & rf19) | (~nxlmark_t0 & rf19) |
                    (~w1h & w2h & w4h & rf14) |
                    ( w1h & ~w2h & w4h & rf14) );
    wire pvcpu = pvas0 & pvas1 & vreq;

    //------------------------------------------------------------------------
    // LS163A @10B wait-state counter (RCLOCK cadence).
    // Sync-cleared while AS is idle; loads {1, PVCPU|/VRAM, /PCM, /EEPROM}
    // while QD=0; counts to 15 and holds; DTACK = (count == 15).
    // Keyed on AS (BAS) only, as on the board: a 68000 write asserts
    // UDS/LDS one CPU clock after AS, and the counter must not wait for them.
    //------------------------------------------------------------------------
    reg [3:0] wcnt;
    always @(posedge clk or posedge reset) begin
        if (reset)
            wcnt <= 4'd0;
        else if (ce_cpu) begin
            if (cpu_as_n || cpu_iack)
                wcnt <= 4'd0;
            else if (!wcnt[3])
                wcnt <= {1'b1,
                         cs_vram_window ? pvcpu : 1'b1,
                         ~cs_oki,
                         ~cs_eeprom};
            else if (wcnt != 4'hF)
                wcnt <= wcnt + 4'd1;
        end
    end

    assign dtack_int = (wcnt == 4'hF);
    assign cpu_dtack_n = (cpu_as_n || cpu_iack) ? 1'b1 : ~dtack_int;

    // CPU read-data mux. Open bus (unstuffed ROM2/AUX/slapstic sites, the
    // write-only watchdog/irq-ack windows, empty VRAM sub-pages, and every
    // truly unmapped address) reads as 0xFFFF from the data-bus pull-ups.
    // The OKI drives only D7..0 (/PCMRD needs no LDS); D15..8 float high.
    assign cpu_data_in = cs_rom       ? rom_data :
                         cs_eeprom    ? eeprom_data :
                         cs_work_ram  ? work_ram_data :
                         cs_slip      ? slip_ram_data :
                         cs_mob       ? mob_ram_data :
                         cs_playfield ? pf_ram_data :
                         cs_pf_ext    ? pfx_ram_data :
                         cs_palette   ? pal_cpu_data :
                         cs_input_p1  ? input_p1_data :
                         cs_input_p2  ? input_p2_data :
                         cs_oki       ? {8'hFF, oki_data} :
                         16'hFFFF;

endmodule
