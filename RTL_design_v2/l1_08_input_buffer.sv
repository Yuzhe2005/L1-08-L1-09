`default_nettype none

import base_plan_l1_08_v2_pkg::*;

module l1_08_v2_input_buffer #(
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT,
    parameter int BUFFER_DEPTH    = INPUT_BUFFER_DEPTH_DEFAULT
) (
    input  logic                         wr_clk,
    input  logic                         wr_reset_n,
    input  logic                         wr_clear,

    input  logic signed [DATA_WIDTH-1:0] in_i,
    input  logic signed [DATA_WIDTH-1:0] in_q,
    input  logic                         in_valid,
    output logic                         in_ready,

    input  logic                         rd_clk,
    input  logic                         rd_reset_n,
    input  logic                         rd_clear,

    output logic signed [DATA_WIDTH-1:0] out_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0] out_q [PARALLEL_FACTOR],
    output logic                         out_valid,
    input  logic                         out_ready,

    output logic                         overflow_error
);
    localparam int BUNDLE_DEPTH = BUFFER_DEPTH / PARALLEL_FACTOR;
    localparam int FIFO_ADDR_W = (BUNDLE_DEPTH <= 2) ? 1 : $clog2(BUNDLE_DEPTH);
    localparam int FIFO_PTR_W  = FIFO_ADDR_W + 1;
    localparam int PACK_COUNT_W = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR);
    localparam int BUNDLE_W = DATA_WIDTH * PARALLEL_FACTOR;

    localparam logic [PACK_COUNT_W-1:0] LastPackLane = PARALLEL_FACTOR - 1;

    logic [BUNDLE_W-1:0] i_mem [BUNDLE_DEPTH];
    logic [BUNDLE_W-1:0] q_mem [BUNDLE_DEPTH];
    logic signed [DATA_WIDTH-1:0] pack_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] pack_q [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] stalled_i;
    logic signed [DATA_WIDTH-1:0] stalled_q;
    logic                         stall_active;
    logic [BUNDLE_W-1:0] write_bundle_i;
    logic [BUNDLE_W-1:0] write_bundle_q;
    logic [PACK_COUNT_W-1:0] pack_count;

    logic [FIFO_PTR_W-1:0] wr_bin;
    logic [FIFO_PTR_W-1:0] wr_gray;
    logic [FIFO_PTR_W-1:0] wr_bin_next;
    logic [FIFO_ADDR_W-1:0] wr_addr;
    logic wr_fire;
    logic wr_full;

    logic [FIFO_PTR_W-1:0] rd_bin;
    logic [FIFO_PTR_W-1:0] rd_gray;
    logic [FIFO_PTR_W-1:0] rd_bin_next;
    logic [FIFO_ADDR_W-1:0] rd_addr;
    logic rd_fire;
    logic rd_empty;

    logic [FIFO_PTR_W-1:0] rd_gray_wr_sync1;
    logic [FIFO_PTR_W-1:0] rd_gray_wr_sync2;
    logic [FIFO_PTR_W-1:0] wr_gray_rd_sync1;
    logic [FIFO_PTR_W-1:0] wr_gray_rd_sync2;

    function automatic logic [FIFO_PTR_W-1:0] bin_to_gray(
        input logic [FIFO_PTR_W-1:0] value
    );
        return (value >> 1) ^ value;
    endfunction

    assign wr_gray = bin_to_gray(wr_bin);
    assign rd_gray = bin_to_gray(rd_bin);
    generate
        if (FIFO_PTR_W == 2) begin : gen_full_depth_two
            assign wr_full = (wr_gray == ~rd_gray_wr_sync2);
        end else begin : gen_full_depth_large
            assign wr_full = (wr_gray == {~rd_gray_wr_sync2[FIFO_PTR_W-1:FIFO_PTR_W-2],
                                          rd_gray_wr_sync2[FIFO_PTR_W-3:0]});
        end
    endgenerate

    assign in_ready = (pack_count != LastPackLane) || !wr_full;
    assign wr_fire = in_valid && in_ready;
    assign wr_addr = wr_bin[FIFO_ADDR_W-1:0];
    assign wr_bin_next = wr_bin + {{(FIFO_PTR_W-1){1'b0}}, (wr_fire && (pack_count == LastPackLane))};

    assign rd_empty = (rd_gray == wr_gray_rd_sync2);
    assign out_valid = !rd_empty;
    assign rd_fire = out_valid && out_ready;
    assign rd_addr = rd_bin[FIFO_ADDR_W-1:0];
    assign rd_bin_next = rd_bin + {{(FIFO_PTR_W-1){1'b0}}, rd_fire};

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            if (lane == (PARALLEL_FACTOR - 1)) begin
                write_bundle_i[lane*DATA_WIDTH +: DATA_WIDTH] = in_i;
                write_bundle_q[lane*DATA_WIDTH +: DATA_WIDTH] = in_q;
            end else begin
                write_bundle_i[lane*DATA_WIDTH +: DATA_WIDTH] = pack_i[lane];
                write_bundle_q[lane*DATA_WIDTH +: DATA_WIDTH] = pack_q[lane];
            end
        end
    end

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            if (out_valid) begin
                out_i[lane] = $signed(i_mem[rd_addr][lane*DATA_WIDTH +: DATA_WIDTH]);
                out_q[lane] = $signed(q_mem[rd_addr][lane*DATA_WIDTH +: DATA_WIDTH]);
            end else begin
                out_i[lane] = '0;
                out_q[lane] = '0;
            end
        end
    end

    always_ff @(posedge wr_clk or negedge wr_reset_n) begin
        if (!wr_reset_n || wr_clear) begin
            wr_bin          <= '0;
            rd_gray_wr_sync1 <= '0;
            rd_gray_wr_sync2 <= '0;
            overflow_error  <= 1'b0;
            pack_count      <= '0;
            stalled_i       <= '0;
            stalled_q       <= '0;
            stall_active    <= 1'b0;
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                pack_i[lane] <= '0;
                pack_q[lane] <= '0;
            end
        end else begin
            rd_gray_wr_sync1 <= rd_gray;
            rd_gray_wr_sync2 <= rd_gray_wr_sync1;

            // Backpressure is legal in valid-ready. Report only a source
            // violation that can lose the sample held during a stall.
            if (!stall_active) begin
                if (in_valid && !in_ready) begin
                    stalled_i    <= in_i;
                    stalled_q    <= in_q;
                    stall_active <= 1'b1;
                end
            end else begin
                if (!in_valid || (in_i != stalled_i) || (in_q != stalled_q)) begin
                    overflow_error <= 1'b1;
                end

                if (!in_valid || in_ready) begin
                    stall_active <= 1'b0;
                end
            end

            if (wr_fire) begin
                if (pack_count == LastPackLane) begin
                    i_mem[wr_addr] <= write_bundle_i;
                    q_mem[wr_addr] <= write_bundle_q;
                    wr_bin         <= wr_bin_next;
                    pack_count     <= '0;
                end else begin
                    pack_i[pack_count] <= in_i;
                    pack_q[pack_count] <= in_q;
                    pack_count         <= pack_count + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge rd_clk or negedge rd_reset_n) begin
        if (!rd_reset_n || rd_clear) begin
            rd_bin          <= '0;
            wr_gray_rd_sync1 <= '0;
            wr_gray_rd_sync2 <= '0;
        end else begin
            wr_gray_rd_sync1 <= wr_gray;
            wr_gray_rd_sync2 <= wr_gray_rd_sync1;

            if (rd_fire) begin
                rd_bin <= rd_bin_next;
            end
        end
    end
endmodule

`default_nettype wire
