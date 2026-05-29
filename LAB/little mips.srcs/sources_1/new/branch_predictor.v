`timescale 1ns / 1ps
`include "headder.vh"

module branch_predictor #(
    parameter ENTRIES = `BHT_ENTRIES,
    parameter INDEX_W = `BHT_INDEX_BITS
)(
    input  wire        clk,
    input  wire        rst,

    // ---- IF stage lookup (combinational) ----
    input  wire [31:0] lookup_pc,
    output wire        pred_taken,
    output wire [31:0] pred_target,

    // ---- EX stage update (sequential) ----
    input  wire        update_valid,
    input  wire [31:0] update_pc,
    input  wire        update_taken,
    input  wire [31:0] update_target
);

    localparam TAG_W = 32 - INDEX_W - 2;  // 26 bits for INDEX_W=4

    // BHT storage
    reg             valid   [0:ENTRIES-1];
    reg [TAG_W-1:0] tag     [0:ENTRIES-1];
    reg [1:0]       counter [0:ENTRIES-1];  // 2-bit saturating: 00=StrongNT, 01=WeakNT, 10=WeakT, 11=StrongT
    reg [31:0]      target  [0:ENTRIES-1];

    // ---- Address decode (combinational) ----
    wire [INDEX_W-1:0] lookup_index = lookup_pc[INDEX_W+1:2];
    wire [TAG_W-1:0]   lookup_tag   = lookup_pc[31:INDEX_W+2];

    wire [INDEX_W-1:0] update_index = update_pc[INDEX_W+1:2];
    wire [TAG_W-1:0]   update_tag   = update_pc[31:INDEX_W+2];

    // ---- Hit detection (combinational) ----
    wire hit = valid[lookup_index] && (tag[lookup_index] == lookup_tag);
    wire update_hit = valid[update_index] && (tag[update_index] == update_tag);
    assign pred_taken  = hit && counter[lookup_index][1];  // MSB: 1=predict taken
    assign pred_target = target[lookup_index];

    // ---- BHT update (sequential) ----
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i]   <= 1'b0;
                tag[i]     <= {TAG_W{1'b0}};
                counter[i] <= 2'b01;  // weak not-taken
                target[i]  <= 32'b0;
            end
        end else if (update_valid) begin
            if (update_hit || ~valid[update_index]) begin
                // Hit or empty entry: update in place
                valid[update_index] <= 1'b1;
                tag[update_index]   <= update_tag;

                if (update_taken) begin
                    // Saturating increment
                    counter[update_index] <= (counter[update_index] == 2'b11)
                        ? 2'b11 : (counter[update_index] + 2'd1);
                    target[update_index] <= update_target;
                end else begin
                    // Saturating decrement
                    counter[update_index] <= (counter[update_index] == 2'b00)
                        ? 2'b00 : (counter[update_index] - 2'd1);
                end
            end else begin
                // Tag mismatch: different branch mapped to same index.
                // If existing entry is consistently not-taken, replace it.
                if (counter[update_index] == 2'b00) begin
                    valid[update_index] <= 1'b1;
                    tag[update_index]   <= update_tag;

                    if (update_taken) begin
                        counter[update_index] <= 2'b10;  // weak taken
                        target[update_index]  <= update_target;
                    end else begin
                        counter[update_index] <= 2'b01;  // weak not-taken
                    end
                end else begin
                    // Existing entry still active: decrement it (decay)
                    counter[update_index] <= counter[update_index] - 2'd1;
                end
            end
        end
    end

endmodule
