// APB PROTOCOL MASTER DESIGN
//fifo module

module sync_fifo #(
  parameter DATA_WIDTH = 16,
  parameter FIFO_DEPTH =16,
  parameter PTR_WIDTH = $clog2(FIFO_DEPTH)
)(
  input i_clock,i_reset,
  input i_w_en,i_r_en,
  
  input [DATA_WIDTH-1:0]i_data,
  
  output reg [DATA_WIDTH-1:0] o_data,
  output o_full,o_empty
   
);
  //memeory allocation
  reg[DATA_WIDTH-1:0] mem[FIFO_DEPTH-1:0];
  
  //read and write pointer 
  reg[PTR_WIDTH-1:0] w_ptr;
  reg[PTR_WIDTH-1:0] r_ptr;
  
  //check queue conditoions
  assign  o_full = ((w_ptr + 1'b1) % FIFO_DEPTH == r_ptr); //full queue
  assign  o_empty= (w_ptr == r_ptr); ;	//empty queue
  
  //for writing the data
  
  always @(posedge i_clock or negedge i_reset)begin
    if(!i_reset)begin
      w_ptr <=0;
      o_data <= 0;
    end
    else if(i_w_en && !o_full)begin
      mem[w_ptr] <= i_data;
      w_ptr <= (w_ptr+1) % FIFO_DEPTH;
    end
  end
  //for reading the data
  
  always @(posedge i_clock or negedge i_reset)begin
    if(!i_reset)begin
      r_ptr <=0;
      o_data <= 0;
    end
    else if(i_r_en && !o_empty)begin
      o_data <= mem[r_ptr];
      r_ptr <= (r_ptr+1) % FIFO_DEPTH;
    end
  end 
endmodule

// APB MASTER module

module apb_master#(
parameter DATA_WIDTH = 16,
parameter ADDR_WIDTH =16,
parameter FIFO_DEPTH = 4
)(

  //port declerations
  
  input wire i_pclk,
  input wire i_prst_n,
  
  // driver to fifo
  
  //commmand from driver from testbench
  input wire 	              i_req,	//enque request 
  input wire	              i_rw,     // w=1 write ,0=read
  input wire [ADDR_WIDTH-1:0] i_addr,	//address
  input wire [DATA_WIDTH-1:0] i_wdata,  //write data
  output wire 	 	 	 	  o_full,
  output wire 				  o_ready, //ready to accept request
  
  //master to driver (response)
  
  output reg				  o_p_error,  //transfer data 
  output reg [DATA_WIDTH-1:0] o_rdata,  //read data
  
  //apb_interface 
  input wire 				  i_pready,
  input wire [DATA_WIDTH-1:0] i_prdata,
  input wire 				  i_pslver,
  output reg 				  o_psel,
  output reg 				  o_pen,
  output reg 				  o_pwrite,
  output reg [DATA_WIDTH-1:0] o_pwr_data,
  output reg [ADDR_WIDTH-1:0] o_paddr
);
  
  //instantiate of four fifos
  
  wire full_addr, full_rw, full_wdata;
  wire empty_addr, empty_rw,empty_wdata;
  
  wire[ADDR_WIDTH-1:0]  rd_addr;      
  wire 	                rd_rw;
  wire [DATA_WIDTH-1:0] rd_wdata;
  reg fsm_rd_en;
 sync_fifo#(
    .DATA_WIDTH(ADDR_WIDTH),
   .FIFO_DEPTH(FIFO_DEPTH))
//    .PTR_WIDTH(PTR_WIDTH)) 
    fifo_addr (
      .i_clock  (i_pclk),
      .i_reset  (i_prst_n),
      .i_w_en  (i_req & ~o_full),
      .i_data    (i_addr),
      .o_data   (rd_addr),
      .o_full   (full_addr),
      .i_r_en  (fsm_rd_en),
      .o_empty  (empty_addr)
    );
  
  sync_fifo #(
    .DATA_WIDTH(1),
    .FIFO_DEPTH(FIFO_DEPTH))
//     .PTR_WIDTH(PTR_WIDTH)) 
  fifo_rw(
    .i_clock  (i_pclk),
    .i_reset  (i_prst_n),
    .i_w_en   (i_req & ~o_full),
    .i_data   (i_rw),
    .o_full   (full_rw),
    .i_r_en   (fsm_rd_en),
    .o_data   (rd_rw),
    .o_empty  (empty_rw)
    );
  
  sync_fifo#(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH))
//     .PTR_WIDTH(PTR_WIDTH)
  fifo_wdata(
    .i_clock (i_pclk),
    .i_reset (i_prst_n),
    .i_w_en	 (i_req & ~o_full),
    .i_data	 (i_wdata),
    .o_full	 (full_wdata),
    .i_r_en	 (fsm_rd_en),
    .o_data	 (rd_wdata),
    .o_empty (empty_wdata)
  );
  
  //global flow control
  
  wire full_global  = full_addr  | full_rw  | full_wdata ;
  wire empty_global = empty_addr | empty_rw | empty_wdata;  
  
  assign o_full = full_global;
  assign o_ready = ~full_global;
  
  
  // APB FSM
  
  localparam IDLE   = 2'd0;
  localparam SETUP  = 2'd1;
  localparam ACCESS = 2'd2;
  
  reg [1:0] state, next_state;
  
  reg [ADDR_WIDTH-1:0] lat_addr;  //latch address
  reg 	   	   	       lat_rw;
  reg [DATA_WIDTH-1:0] lat_wdata;
  
  //sequential logic
  
    always @(posedge i_pclk or negedge i_prst_n) begin
    if (!i_prst_n) begin
      state       <= IDLE;    
      o_p_error   <= 0;
      o_psel      <= 0;
      o_pwrite    <= 0;
      o_pen       <= 0;
      o_pwr_data  <= 0;
      o_paddr     <= 0;
      lat_addr    <= 0;
      lat_rw      <= 0;
      lat_wdata   <= 0;
    end else begin
      state <= next_state;
        
      case (state)
        IDLE: begin
          
          o_psel <= 0;
          o_pen  <= 0;
          
          // Latch FIFO outputs when reading
          if (fsm_rd_en) begin
            lat_addr  <= rd_addr;
            lat_rw    <= rd_rw;
            lat_wdata <= rd_wdata;
          end
        end
        
        SETUP: begin
          o_psel <= 1;
          o_pen <= 0;
          o_pwrite <= lat_rw;
          o_paddr <= lat_addr;
          o_pwr_data <= lat_wdata;
        end
        
        ACCESS: begin
          o_pen <= 1;
          
          if (i_pready) begin
            o_psel    <= 0;
            o_rdata   <= i_prdata;
            o_pen     <= 0;
            o_p_error <= i_pslver;
            
//             if (!lat_rw) begin
//               o_rdata <= i_prdata;
//             end
          end
        end
      endcase
    end
  end
  
  //next state logic 
  
   // Next state logic
  always @(*) begin
    next_state = state;
    fsm_rd_en = 0;
    
    case (state)
      IDLE: begin
        if (!empty_global) begin
          fsm_rd_en = 1;
          next_state = SETUP;
        end
      end
      
      SETUP: begin
        next_state = ACCESS;
      end
      
      ACCESS: begin
        if (!i_pready) begin
          next_state = ACCESS;  // Wait for ready
        end else begin
          next_state = IDLE;    // Transaction complete
        end
      end
      
      default: next_state = IDLE;
    endcase
  end
endmodule
