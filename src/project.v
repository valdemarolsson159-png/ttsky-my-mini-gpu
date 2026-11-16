// ============================================================================
// 1. TOPPMODUL (MyMiniGpu - 4 kärnor, < 16 000 µm²)
// ============================================================================
module MyMiniGpu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [7:0]  ui_in,
    output wire [7:0]  uo_out,
    input  wire [7:0]  uio_in,
    output wire [7:0]  uio_out,
    output wire [7:0]  uio_oe,
    output wire        done
);
    localparam NUM_PES    = 4;
    localparam DATA_WIDTH = 8;

    wire prog_mode     = uio_in[0:0];
    wire prog_write_en = uio_in[1:1];

    wire [15:0] dispatcher_current_instruction;
    wire [15:0] ram_rdata;
    wire        iram_we;
    wire [15:0] iram_wdata;
    wire [3:0]  iram_waddr;
    wire [3:0]  gpu_pc;

    wire [2:0]  alu_op;
    wire [1:0]  raddr_a, raddr_b, waddr;

    wire [3:0]  pe_mask;
    wire        reg_write, load_en, store_en;
    wire        io_ready, io_done_pulse, load_commit;
    wire [31:0] broad_din;
    wire [31:0] broad_dout;

    GpuDispatcher #( .NUM_PES(NUM_PES) ) dispatcher_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start && !prog_mode),
        .io_ready(io_ready),
        .io_done_pulse(io_done_pulse),
        .out_pc(gpu_pc),
        .current_instruction(ram_rdata),
        .out_current_instruction(dispatcher_current_instruction),
        .out_alu_op(alu_op),
        .out_raddr_a(raddr_a),
        .out_raddr_b(raddr_b),
        .out_waddr(waddr),
        .out_pe_mask(pe_mask),
        .out_reg_write(reg_write),
        .out_load_en(load_en),
        .out_store_en(store_en),
        .out_done(done)
    );

    GpuIoInterface #( .NUM_PES(NUM_PES) ) io_inst (
        .clk(clk),
        .rst_n(rst_n),
        .io_din(ui_in),
        .io_dout(uo_out),
        .prog_mode(prog_mode),
        .prog_write_en(prog_write_en),
        .iram_we(iram_we),
        .iram_waddr(iram_waddr),
        .iram_wdata(iram_wdata),
        .req_load(load_en),
        .req_store(store_en),
        .io_ready(io_ready),
        .io_done_pulse(io_done_pulse),
        .load_commit(load_commit),
        .gpu_broad_din(broad_din),
        .gpu_broad_dout(broad_dout)
    );

    wire simd_reg_we = load_en ? load_commit : (reg_write && io_ready);

    SimdCore #( .NUM_PES(NUM_PES), .DATA_WIDTH(DATA_WIDTH) ) simd_inst (
        .clk(clk),
        .rst_n(rst_n),
        .inst_alu_op(alu_op),
        .inst_raddr_a(raddr_a),
        .inst_raddr_b(raddr_b),
        .inst_waddr(waddr),
        .inst_reg_write(simd_reg_we),
        .inst_pe_mask(pe_mask),
        .broad_din(broad_din),
        .broad_load_en(load_en),
        .broad_dout(broad_dout)
    );

    GpuInstructionRam iram_inst (
        .clk(clk),
        .rst_n(rst_n),
        .we(iram_we),
        .waddr(iram_waddr),
        .wdata(iram_wdata),
        .raddr(gpu_pc),
        .rdata(ram_rdata)
    );

    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000;
endmodule


// ============================================================================
// 2. INSTRUKTIONS-RAM (6 x 16 bitar)
// ============================================================================
module GpuInstructionRam (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        we,
    input  wire [3:0]  waddr,
    input  wire [15:0] wdata,
    input  wire [3:0]  raddr,
    output wire [15:0] rdata
);
    reg [15:0] mem [0:5];
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 6; k = k + 1) begin
                mem[k] <= 16'hC000;
            end
        end else if (we && (waddr < 4'd6)) begin
            mem[waddr[2:0]] <= wdata;
        end
    end

    assign rdata = (raddr < 4'd6) ? mem[raddr[2:0]] : 16'hC000;
endmodule


// ============================================================================
// 3. I/O-GRÄNSSNITT (32-bitars skiftregister)
// ============================================================================
module GpuIoInterface #(
    parameter NUM_PES = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  io_din,
    output wire [7:0]  io_dout,
    input  wire        prog_mode,
    input  wire        prog_write_en,
    output reg         iram_we,
    output reg  [3:0]  iram_waddr,
    output reg  [15:0] iram_wdata,
    input  wire        req_load,
    input  wire        req_store,
    output wire        io_ready,
    output reg         io_done_pulse,
    output reg         load_commit,
    output wire [31:0] gpu_broad_din,
    input  wire [31:0] gpu_broad_dout
);
    localparam STATE_IDLE  = 2'b00;
    localparam STATE_LOAD  = 2'b01;
    localparam STATE_STORE = 2'b10;

    reg [1:0]  stream_cnt;
    reg [1:0]  state;
    reg        byte_sel;
    reg        prog_write_d;
    reg [31:0] shift_buffer;

    wire prog_write_rise = prog_write_en && !prog_write_d;

    assign gpu_broad_din = shift_buffer;
    assign io_dout       = shift_buffer[7:0];
    assign io_ready      = (state == STATE_IDLE) && !prog_mode && !load_commit && !io_done_pulse;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iram_we      <= 1'b0;
            iram_waddr   <= 4'd0;
            iram_wdata   <= 16'd0;
            byte_sel     <= 1'b0;
            prog_write_d <= 1'b0;
        end else begin
            prog_write_d <= prog_write_en;
            iram_we      <= 1'b0;

            if (iram_we) begin
                iram_waddr <= iram_waddr + 1'b1;
            end

            if (prog_mode) begin
                if (prog_write_rise) begin
                    if (byte_sel == 1'b0) begin
                        iram_wdata[15:8] <= io_din;
                        byte_sel         <= 1'b1;
                    end else begin
                        iram_wdata[7:0]  <= io_din;
                        iram_we          <= 1'b1;
                        byte_sel         <= 1'b0;
                    end
                end
            end else begin
                iram_waddr <= 4'd0;
                byte_sel   <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= STATE_IDLE;
            stream_cnt    <= 2'd0;
            io_done_pulse <= 1'b0;
            load_commit   <= 1'b0;
            shift_buffer  <= 32'd0;
        end else begin
            io_done_pulse <= 1'b0;
            load_commit   <= 1'b0;

            if (load_commit) begin
                io_done_pulse <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    stream_cnt <= 2'd0;
                    if (!prog_mode && !load_commit && !io_done_pulse) begin
                        if (req_load) begin
                            state <= STATE_LOAD;
                        end else if (req_store) begin
                            shift_buffer <= gpu_broad_dout;
                            state        <= STATE_STORE;
                        end
                    end
                end

                STATE_LOAD: begin
                    shift_buffer <= {io_din, shift_buffer[31:8]};
                    if (stream_cnt == 2'd3) begin
                        state       <= STATE_IDLE;
                        load_commit <= 1'b1;
                    end else begin
                        stream_cnt <= stream_cnt + 1'b1;
                    end
                end

                STATE_STORE: begin
                    shift_buffer <= {8'd0, shift_buffer[31:8]};
                    if (stream_cnt == 2'd3) begin
                        state         <= STATE_IDLE;
                        io_done_pulse <= 1'b1;
                    end else begin
                        stream_cnt <= stream_cnt + 1'b1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule


// ============================================================================
// 4. DISPATCHER
// ============================================================================
module GpuDispatcher #(
    parameter NUM_PES = 4
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,
    input  wire               io_ready,
    input  wire               io_done_pulse,
    output wire [3:0]         out_pc,
    input  wire [15:0]        current_instruction,
    output wire [15:0]        out_current_instruction,
    output reg  [2:0]         out_alu_op,

    output reg  [1:0]         out_raddr_a,
    output reg  [1:0]         out_raddr_b,
    output reg  [1:0]         out_waddr,
    output reg  [NUM_PES-1:0] out_pe_mask,
    output reg                out_reg_write,
    output reg                out_load_en,
    output reg                out_store_en,
    
    output reg                out_done
);
    reg [3:0] pc;
    reg       running;

    assign out_pc = pc;
    assign out_current_instruction = current_instruction;

    wire [1:0] opcode = current_instruction[15:14];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc       <= 4'd0;
            running  <= 1'b0;
            out_done <= 1'b0;
        end else begin
            if (start && !running && !out_done) begin
                running <= 1'b1;
                pc      <= 4'd0;
            end else if (running) begin
                if (opcode == 2'b11) begin
                    running  <= 1'b0;
                    out_done <= 1'b1;
                end else if (opcode == 2'b01 || opcode == 2'b10) begin
                    if (io_done_pulse) begin
                        pc <= pc + 1'b1;
                    end
                end else if (io_ready) begin
                    pc <= pc + 1'b1;
                end
            end
        end
    end

    always @(*) begin
out_alu_op = {current_instruction[11:11], current_instruction[13:12]};

out_waddr     = current_instruction[11:10];
out_raddr_a   = current_instruction[9:8];
out_raddr_b   = current_instruction[7:6];
out_pe_mask   = current_instruction[3:0];
out_reg_write = 1'b0;
out_load_en   = 1'b0;
out_store_en  = 1'b0;
if (running) begin
case (opcode)
2'b00: out_reg_write = 1'b1;
2'b01: begin
out_load_en   = 1'b1;
out_reg_write = 1'b1;
end
2'b10: begin
out_store_en  = 1'b1;
end
default: begin
out_reg_write = 1'b0;
out_load_en   = 1'b0;
out_store_en  = 1'b0;
end
endcase
end
end
endmodule
// ============================================================================
// 5. SIMD-CORE (4 parallella kärnor)
// ============================================================================
module SimdCore #(
parameter NUM_PES = 4,
parameter DATA_WIDTH = 8
)(
input  wire        clk,
input  wire        rst_n,
input  wire [2:0]  inst_alu_op,
input  wire [1:0]  inst_raddr_a,
input  wire [1:0]  inst_raddr_b,
input  wire [1:0]  inst_waddr,
input  wire        inst_reg_write,
input  wire [3:0]  inst_pe_mask,
input  wire [31:0] broad_din,
input  wire        broad_load_en,
output wire [31:0] broad_dout
);
genvar i;
generate
for (i = 0; i < NUM_PES; i = i + 1) begin : pe_array
ProcessingElement #(
.DATA_WIDTH(DATA_WIDTH),
.REG_ADDR_WIDTH(2),
.NUM_PES(NUM_PES),
.PE_ID(i)
) pe_inst (
.clk(clk),
.rst_n(rst_n),
.alu_op(inst_alu_op),
.raddr_a(inst_raddr_a),
.raddr_b(inst_raddr_b),
.waddr(inst_waddr),
.reg_write(inst_reg_write),
.vector_din(broad_din[i*8 +: 8]),
.load_en(broad_load_en),
.pe_mask(inst_pe_mask),
.vector_dout(broad_dout[i*8 +: 8])
);
end
endgenerate
endmodule
// ============================================================================
// 6. PROCESSING ELEMENT (2 register r0-r1 utan reset + delad adderare)
// ============================================================================
module ProcessingElement #(
parameter DATA_WIDTH = 8,
parameter REG_ADDR_WIDTH = 2,
parameter NUM_PES = 4,
parameter PE_ID = 0
)(
input  wire                      clk,
input  wire                      rst_n,
input  wire [2:0]                alu_op,
input  wire [REG_ADDR_WIDTH-1:0] raddr_a,
input  wire [REG_ADDR_WIDTH-1:0] raddr_b,
input  wire [REG_ADDR_WIDTH-1:0] waddr,
input  wire                      reg_write,
input  wire [DATA_WIDTH-1:0]     vector_din,
input  wire                      load_en,
input  wire [NUM_PES-1:0]        pe_mask,
output wire [DATA_WIDTH-1:0]     vector_dout
);
reg [DATA_WIDTH-1:0] r0, r1;
wire my_mask_bit = pe_mask[PE_ID:PE_ID];
wire [DATA_WIDTH-1:0] reg_a = raddr_a[0:0] ? r1 : r0;
wire [DATA_WIDTH-1:0] reg_b = raddr_b[0:0] ? r1 : r0;
    wire is_sub = (alu_op == 3'b001);
    wire [DATA_WIDTH-1:0] b_in = is_sub ? ~reg_b : reg_b;
    wire [DATA_WIDTH-1:0] add_sub_res = reg_a + b_in + {{(DATA_WIDTH-1){1'b0}}, is_sub};


        // Kompakt 3x3-bitars multiplikator (klarar talen 0..7 * 0..7 = 0..49)
    wire [5:0] prod_3x3 = reg_a[2:0] * reg_b[2:0];
    wire [7:0] mul_res  = {2'b00, prod_3x3};


    reg [DATA_WIDTH-1:0] alu_out;
    always @(*) begin
        case (alu_op)
            2'b00,
            2'b01:   alu_out = add_sub_res;     // ADD / SUB
            2'b10:   alu_out = reg_a & reg_b;   // AND
            2'b11:   alu_out = mul_res;         // MUL (3x3 -> 0..49)
            default: alu_out = {DATA_WIDTH{1'b0}};
        endcase
    end


wire [DATA_WIDTH-1:0] write_data = load_en ? vector_din : alu_out;
always @(posedge clk) begin
if (reg_write && my_mask_bit) begin
if (waddr[0:0]) r1 <= write_data;
else            r0 <= write_data;
end
end
assign vector_dout = reg_a;
endmodule
module tt_um_my_mini_gpu (
    input  wire [7:0] ui_in,    // Pixeldata / program in
    output wire [7:0] uo_out,   // 8-bitars RGB332-färg (256 färger) / data ut
    input  wire [7:0] uio_in,   // Kontrollsignaler in
    output wire [7:0] uio_out,  // 4-bitars RGBI-färg (16 färger) + done ut
    output wire [7:0] uio_oe,   // Output Enable
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire gpu_done;
    wire [7:0] unused_uio_out;
    wire [7:0] unused_uio_oe;

    MyMiniGpu gpu_core (
        .clk(clk),
        .rst_n(rst_n && ena),
        .start(uio_in[2:2]),
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(unused_uio_out),
        .uio_oe(unused_uio_oe),
        .done(gpu_done)
    );

    // Direkt 4-bitars RGBI-färgutgång på uio[7:4]:
    // uio = Röd (R)
    // uio = Grön (G)
    // uio = Blå (B)
    // uio = Intensitet (I)
    assign uio_out = {uo_out[3:0], gpu_done, 3'b000};
    assign uio_oe  = 8'b11111000; // Pinnar 7..3 = utgångar, pinnar 2..0 = ingångar

    wire _unused = &{1'b0, uio_in[7:3], unused_uio_out, unused_uio_oe};
endmodule

