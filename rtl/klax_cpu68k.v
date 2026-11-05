// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
//============================================================================
// Klax 68000 CPU: fx68k (cycle-exact MC68000) with native bus pins
//
// The board's MC68000 runs at 7.159 MHz (14.318 MHz / 2). Here it lives in
// the clk_sys domain and advances on two clock enables:
//   enPhi1 = ce_cpu         (asserted one clk before the CPU clock's HIGH phase)
//   enPhi2 = ce_cpu + 4 clk (one clk before the LOW phase: 50% duty at /8)
// The 4-clk point is the same RCLOCKB sub-phase the 9W VRAM arbiter replica
// in klax_cpu_bus uses, so the CPU clock edges and the board's RCLOCK-domain
// logic (10B wait-state counter, 9W slot machine) stay phase-aligned.
//
// fx68k registers DTACK on enPhi2 (the S4 falling edge) and VPA on enPhi1,
// exactly like the real part's synchronizers, so the existing 10B/9W DTACK
// model and the combinational IACK VPA connect straight through.
//
// IPL, DTACK and VPA come from synchronous clk_sys logic, so no extra
// synchronizer flops are inserted (they would add latency the board lacks).
//
// ce_cpu must be a single-clk pulse at least 8 clk apart; a tied-high
// ce_cpu never produces enPhi2 and the CPU stays in reset-like idle.
//============================================================================

module klax_cpu68k (
    input               clk,
    input               reset,      // synchronous, active high (incl. watchdog)
    input               ce_cpu,     // CPU clock rising-edge enable (clk_sys/8)

    input       [2:0]   ipl_n,
    input               dtack_n,
    input               vpa_n,
    input       [15:0]  data_in,

    output      [23:0]  addr,       // byte address, A0 = 0
    output      [15:0]  data_out,
    output      [2:0]   fc,
    output              as_n,
    output              uds_n,
    output              lds_n,
    output              rw_n
);

    // Half-period phase counter: 1 on the clk after ce_cpu, enPhi2 at 4.
    reg [2:0] ph = 3'd0;
    always @(posedge clk) begin
        if (ce_cpu)
            ph <= 3'd1;
        else if (ph != 3'd0)
            ph <= ph + 3'd1;
    end
    wire en_phi2 = (ph == 3'd4);

    wire [23:1] eab;
    wire        e_unused, vma_unused, bg_unused, rst_out_unused, halted_unused;

    fx68k u_fx68k (
        .clk      (clk),
        .HALTn    (1'b1),
        .extReset (reset),
        .pwrUp    (reset),
        .enPhi1   (ce_cpu),
        .enPhi2   (en_phi2),

        .eRWn     (rw_n),
        .ASn      (as_n),
        .LDSn     (lds_n),
        .UDSn     (uds_n),
        .E        (e_unused),
        .VMAn     (vma_unused),
        .FC0      (fc[0]),
        .FC1      (fc[1]),
        .FC2      (fc[2]),
        .BGn      (bg_unused),
        .oRESETn  (rst_out_unused),
        .oHALTEDn (halted_unused),
        .DTACKn   (dtack_n),
        .VPAn     (vpa_n),
        .BERRn    (1'b1),
        .BRn      (1'b1),
        .BGACKn   (1'b1),
        .IPL0n    (ipl_n[0]),
        .IPL1n    (ipl_n[1]),
        .IPL2n    (ipl_n[2]),
        .iEdb     (data_in),
        .oEdb     (data_out),
        .eab      (eab)
    );

    assign addr = {eab, 1'b0};

endmodule
