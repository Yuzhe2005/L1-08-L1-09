`default_nettype none

import base_plan_l1_09_v2_pkg::*;

module l1_09_v2_coeff_bank #(
    parameter int SECTION_COUNT = SECTION_COUNT_DEFAULT,
    parameter int COEFF_WIDTH   = COEFF_WIDTH_DEFAULT
) (
    input  logic                          clk,
    input  logic                          reset_n,
    output logic                          coeffs_ready,
    output logic signed [COEFF_WIDTH-1:0] a1 [SECTION_COUNT],
    output logic signed [COEFF_WIDTH-1:0] a2 [SECTION_COUNT]
);
    logic signed [COEFF_WIDTH-1:0] coeff_a1 [SECTION_COUNT];
    logic signed [COEFF_WIDTH-1:0] coeff_a2 [SECTION_COUNT];

    assign a1           = coeff_a1;
    assign a2           = coeff_a2;
    assign coeffs_ready = reset_n;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            `include `BASE_PLAN_L1_09_V2_COEFF_RESET_SVH
        end
    end
endmodule

module l1_09_v2_parallel_section #(
    parameter int DATA_W          = DATA_WIDTH_DEFAULT,
    parameter int COEFF_W         = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACC_W           = ACCUM_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W  = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1)
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic                         clear,
    input  logic                         stage_en,
    input  logic [ACTIVE_LANES_W-1:0]    active_lanes,
    input  logic signed [DATA_W-1:0]     x_in [PARALLEL_FACTOR],
    input  logic signed [COEFF_W-1:0]    a1,
    input  logic signed [COEFF_W-1:0]    a2,
    output logic signed [DATA_W-1:0]     y_out [PARALLEL_FACTOR]
);
    localparam int MULT_W = DATA_W + COEFF_W;

    logic signed [DATA_W-1:0] x1;
    logic signed [DATA_W-1:0] x2;
    logic signed [DATA_W-1:0] y1;
    logic signed [DATA_W-1:0] y2;
    logic signed [DATA_W-1:0] x0_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] x1_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] x2_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y1_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y2_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y_next [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x0_a2 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x1_a1 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x2_unity [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_y1_a1 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_y2_a2 [PARALLEL_FACTOR];
    logic signed [ACC_W-1:0]  acc [PARALLEL_FACTOR];
    int unsigned              active_lane_count;

    function automatic logic signed [DATA_W-1:0] round_sat_qx(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] rounded;
        logic signed [ACC_W-1:0] shifted;
        logic signed [ACC_W-1:0] max_out;
        logic signed [ACC_W-1:0] min_out;
        begin
            max_out = {{(ACC_W-DATA_W){1'b0}}, 1'b0, {DATA_W-1{1'b1}}};
            min_out = {{(ACC_W-DATA_W){1'b1}}, 1'b1, {DATA_W-1{1'b0}}};
            rounded = (COEFF_FRAC_BITS == 0) ? value : (value + (1 <<< (COEFF_FRAC_BITS - 1)));
            shifted = rounded >>> COEFF_FRAC_BITS;
            if (shifted > max_out) begin
                round_sat_qx = {1'b0, {DATA_W-1{1'b1}}};
            end else if (shifted < min_out) begin
                round_sat_qx = {1'b1, {DATA_W-1{1'b0}}};
            end else begin
                round_sat_qx = shifted[DATA_W-1:0];
            end
        end
    endfunction

    function automatic logic signed [ACC_W-1:0] sign_extend_prod(
        input logic signed [MULT_W-1:0] value
    );
        return {{(ACC_W - MULT_W){value[MULT_W-1]}}, value};
    endfunction

    always_comb begin
        active_lane_count = int'(active_lanes);
        if (active_lane_count > PARALLEL_FACTOR) begin
            active_lane_count = PARALLEL_FACTOR;
        end

        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            x0_sel[lane] = x_in[lane];
            if (lane == 0) begin
                x1_sel[lane] = x1;
                x2_sel[lane] = x2;
                y1_sel[lane] = y1;
                y2_sel[lane] = y2;
            end else if (lane == 1) begin
                x1_sel[lane] = x_in[0];
                x2_sel[lane] = x1;
                y1_sel[lane] = y_next[0];
                y2_sel[lane] = y1;
            end else begin
                x1_sel[lane] = x_in[lane - 1];
                x2_sel[lane] = x_in[lane - 2];
                y1_sel[lane] = y_next[lane - 1];
                y2_sel[lane] = y_next[lane - 2];
            end

            prod_x0_a2[lane]    = x0_sel[lane] * a2;
            prod_x1_a1[lane]    = x1_sel[lane] * a1;
            prod_x2_unity[lane] = {{COEFF_W{x2_sel[lane][DATA_W-1]}}, x2_sel[lane]} <<< COEFF_FRAC_BITS;
            prod_y1_a1[lane]    = y1_sel[lane] * a1;
            prod_y2_a2[lane]    = y2_sel[lane] * a2;
            acc[lane] = sign_extend_prod(prod_x0_a2[lane])
                      + sign_extend_prod(prod_x1_a1[lane])
                      + sign_extend_prod(prod_x2_unity[lane])
                      - sign_extend_prod(prod_y1_a1[lane])
                      - sign_extend_prod(prod_y2_a2[lane]);
            y_next[lane] = round_sat_qx(acc[lane]);
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            x1 <= '0;
            x2 <= '0;
            y1 <= '0;
            y2 <= '0;
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_out[lane] <= '0;
            end
        end else if (stage_en) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                if (lane < active_lane_count) begin
                    y_out[lane] <= y_next[lane];
                end else begin
                    y_out[lane] <= '0;
                end
            end

            if (active_lane_count == 1) begin
                x1 <= x_in[0];
                x2 <= x1;
                y1 <= y_next[0];
                y2 <= y1;
            end else if (active_lane_count > 1) begin
                x1 <= x_in[active_lane_count - 1];
                x2 <= x_in[active_lane_count - 2];
                y1 <= y_next[active_lane_count - 1];
                y2 <= y_next[active_lane_count - 2];
            end
        end
    end
endmodule

module l1_09_v2_parallel_core #(
    parameter int SECTION_COUNT   = SECTION_COUNT_DEFAULT,
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH     = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH     = ACCUM_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W  = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1)
) (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              clear,
    input  logic signed [DATA_WIDTH-1:0]      x_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0]      x_q [PARALLEL_FACTOR],
    input  logic [ACTIVE_LANES_W-1:0]         active_lanes,
    input  logic                              in_valid,
    output logic                              input_ready,
    input  logic                              bypass,
    output logic signed [DATA_WIDTH-1:0]      y_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0]      y_q [PARALLEL_FACTOR],
    output logic [PARALLEL_FACTOR-1:0]        y_valid,
    output logic                              coeffs_ready,
    output logic                              active_lanes_error
);
    logic signed [COEFF_WIDTH-1:0] coeff_a1 [SECTION_COUNT];
    logic signed [COEFF_WIDTH-1:0] coeff_a2 [SECTION_COUNT];
    logic signed [DATA_WIDTH-1:0]  stage_i [SECTION_COUNT+1][PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0]  stage_q [SECTION_COUNT+1][PARALLEL_FACTOR];
    logic [SECTION_COUNT:0]        stage_valid;
    logic [ACTIVE_LANES_W-1:0]     stage_active_lanes [SECTION_COUNT+1];
    logic                          run_valid;
    logic                          filter_in_valid;
    int unsigned                   input_lane_count;
    int unsigned                   output_lane_count;

    always_comb begin
        input_lane_count = int'(active_lanes);
        if (input_lane_count > PARALLEL_FACTOR) begin
            input_lane_count = PARALLEL_FACTOR;
        end

        output_lane_count = int'(stage_active_lanes[SECTION_COUNT]);
        if (output_lane_count > PARALLEL_FACTOR) begin
            output_lane_count = PARALLEL_FACTOR;
        end
    end

    assign active_lanes_error = (int'(active_lanes) > PARALLEL_FACTOR);
    assign input_ready = coeffs_ready && !clear && !active_lanes_error;
    assign run_valid = in_valid
                     && input_ready
                     && (input_lane_count != 0);
    assign filter_in_valid = run_valid && !bypass;
    assign stage_valid[0] = filter_in_valid;
    assign stage_active_lanes[0] = active_lanes;

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            stage_i[0][lane] = x_i[lane];
            stage_q[0][lane] = x_q[lane];
        end
    end

    l1_09_v2_coeff_bank #(
        .SECTION_COUNT(SECTION_COUNT),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) u_coeff_bank (
        .clk(clk),
        .reset_n(reset_n),
        .coeffs_ready(coeffs_ready),
        .a1(coeff_a1),
        .a2(coeff_a2)
    );

    generate
        for (genvar sec = 0; sec < SECTION_COUNT; sec++) begin : gen_sections
            l1_09_v2_parallel_section #(
                .DATA_W(DATA_WIDTH),
                .COEFF_W(COEFF_WIDTH),
                .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
                .ACC_W(ACCUM_WIDTH),
                .PARALLEL_FACTOR(PARALLEL_FACTOR),
                .ACTIVE_LANES_W(ACTIVE_LANES_W)
            ) u_i_section (
                .clk(clk),
                .reset_n(reset_n),
                .clear(clear),
                .stage_en(stage_valid[sec]),
                .active_lanes(stage_active_lanes[sec]),
                .x_in(stage_i[sec]),
                .a1(coeff_a1[sec]),
                .a2(coeff_a2[sec]),
                .y_out(stage_i[sec + 1])
            );

            l1_09_v2_parallel_section #(
                .DATA_W(DATA_WIDTH),
                .COEFF_W(COEFF_WIDTH),
                .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
                .ACC_W(ACCUM_WIDTH),
                .PARALLEL_FACTOR(PARALLEL_FACTOR),
                .ACTIVE_LANES_W(ACTIVE_LANES_W)
            ) u_q_section (
                .clk(clk),
                .reset_n(reset_n),
                .clear(clear),
                .stage_en(stage_valid[sec]),
                .active_lanes(stage_active_lanes[sec]),
                .x_in(stage_q[sec]),
                .a1(coeff_a1[sec]),
                .a2(coeff_a2[sec]),
                .y_out(stage_q[sec + 1])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            for (int sec = 1; sec <= SECTION_COUNT; sec++) begin
                stage_valid[sec]       <= 1'b0;
                stage_active_lanes[sec] <= '0;
            end
        end else begin
            for (int sec = 1; sec <= SECTION_COUNT; sec++) begin
                stage_valid[sec] <= stage_valid[sec - 1];
                if (stage_valid[sec - 1]) begin
                    stage_active_lanes[sec] <= stage_active_lanes[sec - 1];
                end else begin
                    stage_active_lanes[sec] <= '0;
                end
            end
        end
    end

    always_comb begin
        y_valid = '0;
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            y_i[lane] = '0;
            y_q[lane] = '0;
        end

        if (run_valid && bypass) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                if (lane < input_lane_count) begin
                    y_i[lane]     = x_i[lane];
                    y_q[lane]     = x_q[lane];
                    y_valid[lane] = 1'b1;
                end
            end
        end else if (stage_valid[SECTION_COUNT]) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                if (lane < output_lane_count) begin
                    y_i[lane]     = stage_i[SECTION_COUNT][lane];
                    y_q[lane]     = stage_q[SECTION_COUNT][lane];
                    y_valid[lane] = 1'b1;
                end
            end
        end
    end
endmodule

module l1_09_v2_from_l1_08_parallel #(
    parameter int SECTION_COUNT   = SECTION_COUNT_DEFAULT,
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH     = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH     = ACCUM_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W  = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1),
    parameter int PACKER_DEPTH    = PARALLEL_FACTOR * 2,
    parameter int LEVEL_W         = $clog2(PACKER_DEPTH + PARALLEL_FACTOR + 1)
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic                         clear,
    input  logic signed [DATA_WIDTH-1:0] l1_08_y_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0] l1_08_y_q [PARALLEL_FACTOR],
    input  logic [PARALLEL_FACTOR-1:0]   l1_08_y_valid,
    output logic                         input_ready,
    input  logic                         bypass,
    output logic signed [DATA_WIDTH-1:0] y_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0] y_q [PARALLEL_FACTOR],
    output logic [PARALLEL_FACTOR-1:0]   y_valid,
    output logic                         coeffs_ready,
    output logic [LEVEL_W-1:0]           packer_level,
    output logic                         packer_overflow_error
);
    localparam logic [ACTIVE_LANES_W-1:0] FULL_ACTIVE_LANES = PARALLEL_FACTOR;

    logic signed [DATA_WIDTH-1:0] i_queue [PACKER_DEPTH];
    logic signed [DATA_WIDTH-1:0] q_queue [PACKER_DEPTH];
    logic signed [DATA_WIDTH-1:0] push_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] push_q [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] core_x_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] core_x_q [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] core_y_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] core_y_q [PARALLEL_FACTOR];
    logic [PARALLEL_FACTOR-1:0]   core_y_valid;
    logic                         core_input_ready;
    logic                         core_in_valid;
    logic                         core_active_lanes_error;
    logic                         packer_ready;
    logic                         push_fire;
    int unsigned                  level_count;
    int unsigned                  push_count;
    int unsigned                  pop_count;
    int unsigned                  retained_count;
    int unsigned                  available_after_pop;

    always_comb begin
        push_count = 0;
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            push_i[lane] = '0;
            push_q[lane] = '0;
        end

        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            if (l1_08_y_valid[lane]) begin
                push_i[push_count] = l1_08_y_i[lane];
                push_q[push_count] = l1_08_y_q[lane];
                push_count++;
            end
        end

        core_in_valid = !bypass
                      && (level_count >= PARALLEL_FACTOR)
                      && core_input_ready;
        pop_count = core_in_valid ? PARALLEL_FACTOR : 0;
        retained_count = level_count - pop_count;
        available_after_pop = PACKER_DEPTH - level_count + pop_count;
        packer_ready = (push_count <= available_after_pop);
        push_fire = !bypass && packer_ready && (push_count != 0);
        input_ready = bypass ? 1'b1 : packer_ready;
        packer_level = level_count;

        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            core_x_i[lane] = i_queue[lane];
            core_x_q[lane] = q_queue[lane];
        end
    end

    l1_09_v2_parallel_core #(
        .SECTION_COUNT(SECTION_COUNT),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .PARALLEL_FACTOR(PARALLEL_FACTOR),
        .ACTIVE_LANES_W(ACTIVE_LANES_W)
    ) u_core (
        .clk(clk),
        .reset_n(reset_n),
        .clear(clear || bypass),
        .x_i(core_x_i),
        .x_q(core_x_q),
        .active_lanes(FULL_ACTIVE_LANES),
        .in_valid(core_in_valid),
        .input_ready(core_input_ready),
        .bypass(1'b0),
        .y_i(core_y_i),
        .y_q(core_y_q),
        .y_valid(core_y_valid),
        .coeffs_ready(coeffs_ready),
        .active_lanes_error(core_active_lanes_error)
    );

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear || bypass) begin
            for (int idx = 0; idx < PACKER_DEPTH; idx++) begin
                i_queue[idx] <= '0;
                q_queue[idx] <= '0;
            end
            level_count           <= 0;
            packer_overflow_error <= 1'b0;
        end else begin
            if ((push_count != 0) && !packer_ready) begin
                packer_overflow_error <= 1'b1;
            end

            for (int idx = 0; idx < PACKER_DEPTH; idx++) begin
                if (idx < retained_count) begin
                    i_queue[idx] <= i_queue[idx + pop_count];
                    q_queue[idx] <= q_queue[idx + pop_count];
                end else if (push_fire && (idx < (retained_count + push_count))) begin
                    i_queue[idx] <= push_i[idx - retained_count];
                    q_queue[idx] <= push_q[idx - retained_count];
                end else begin
                    i_queue[idx] <= '0;
                    q_queue[idx] <= '0;
                end
            end

            if (push_fire) begin
                level_count <= retained_count + push_count;
            end else begin
                level_count <= retained_count;
            end
        end
    end

    always_comb begin
        if (bypass) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_i[lane]     = l1_08_y_i[lane];
                y_q[lane]     = l1_08_y_q[lane];
                y_valid[lane] = l1_08_y_valid[lane];
            end
        end else begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_i[lane]     = core_y_i[lane];
                y_q[lane]     = core_y_q[lane];
                y_valid[lane] = core_y_valid[lane];
            end
        end
    end
endmodule

`default_nettype wire
