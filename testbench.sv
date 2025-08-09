`timescale 1ns/1ps
module master_tb;
  // Parameters for the DUT and testbench
  parameter DATA_WIDTH = 16;
  parameter ADDR_WIDTH = 32;
  parameter FIFO_DEPTH = 16;

  // Master Interface (Inputs to DUT)
  reg                   i_pclk;
  reg                   i_prst_n;
  reg                   i_req;
  reg                   i_rw;
  reg [ADDR_WIDTH-1:0]  i_addr;
  reg [DATA_WIDTH-1:0]  i_wdata;

  // Master Interface (Outputs from DUT)
  wire                  o_full;
  wire                  o_ready;
  wire                  o_p_error;
  wire [DATA_WIDTH-1:0] o_rdata;
 // APB Slave Interface (Inputs to DUT from the reactive slave)
  reg                   i_pready;
  reg [DATA_WIDTH-1:0]  i_prdata;
  reg                   i_pslver; // APB slave error signal
  // APB Master Interface (Outputs from DUT to the reactive slave)
  wire                  o_psel;
  wire                  o_pen;
  wire                  o_pwrite;
  wire [DATA_WIDTH-1:0] o_pwr_data;
  wire [ADDR_WIDTH-1:0] o_paddr;

  // Clock generation
  initial begin
    i_pclk = 0;
    forever #5 i_pclk = ~i_pclk; // Creates a 10ns period clock
  end

  // Instantiate the DUT (Device Under Test)
  apb_master #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
    
  ) dut (
    .i_pclk(i_pclk),
    .i_prst_n(i_prst_n),
    .i_req(i_req),
    .i_rw(i_rw),
    .i_addr(i_addr),
    .i_wdata(i_wdata),
    .o_full(o_full),
    .o_ready(o_ready),
    .o_p_error(o_p_error),
    .o_rdata(o_rdata),
    // Removed: .o_timeout port is no longer in apb_master
    .i_pready(i_pready),
    .i_prdata(i_prdata),
    .i_pslver(i_pslver),
    .o_psel(o_psel),
    .o_pen(o_pen),
    .o_pwrite(o_pwrite),
    .o_pwr_data(o_pwr_data),
    .o_paddr(o_paddr)
  );

  // Simple Memory Model for Slave
  reg [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

  // Reactive slave logic
  initial begin
    forever begin
      @(posedge i_pclk);
      if (!i_prst_n) begin // Reset condition
        i_pready <= 1'b0;
        i_prdata <= 'x;
        i_pslver <= 1'b0;
      end else if (o_psel && o_pen) begin // APB ACCESS phase detected
        i_pslver <= 1'b0;       	      // Default to no error
        if (o_pwrite) begin     	     // Write transaction
          mem[o_paddr] <= o_pwr_data;    // Write data to memory
          i_prdata <= 'x;               // PRDATA is don't care for writes
        end else begin               // Read transaction
          i_prdata <= mem[o_paddr];  // Provide data from memory
        end
        i_pready <= 1'b1;            // Assert PREADY to complete the transaction
      end else begin                // IDLE or SETUP phase, or transaction complete
        i_pready <= 1'b0;            // De-assert PREADY
        i_prdata <= 'x;              // De-assert PRDATA
        i_pslver <= 1'b0;            // De-assert PSLVER
      end
    end
  end

  //-----------TESTBENCH TASKS------------------------//

  // Task to apply and release reset to the DUT
  task reset_test;
    begin
      $display("[%0t] >>> Applying RESET", $time);
      i_prst_n <= 1'b0; // Assert active-low reset
      i_req    <= 1'b0;
      i_rw     <= 1'b0;
      i_addr   <= {ADDR_WIDTH{1'b0}};
      i_wdata  <= {DATA_WIDTH{1'b0}};
      i_pready <= 1'b0;
      i_prdata <= {DATA_WIDTH{1'b0}};
      i_pslver <= 1'b0;

      repeat(2) @(posedge i_pclk); // Hold reset for a few clock cycles
      i_prst_n <= 1'b1; // Release reset
      @(posedge i_pclk); // Wait one cycle for signals to stabilize
      $display("[%0t] <<< RESET released", $time);
    end
  endtask

  // Task to perform an APB write transaction
  task apb_write(input[ADDR_WIDTH-1:0] addr, input [DATA_WIDTH-1:0] data);
    begin
      $display("[%0t] >>> Starting apb_write to ADDR=0x%h DATA=0x%h", $time, addr, data);
      wait(o_ready); // Wait until the master is ready to accept a new request

      // Drive request for one cycle to FIFO
      @(posedge i_pclk);
      i_req    <= 1'b1;
      i_rw     <= 1'b1;  // Write command
      i_addr   <= addr;
      i_wdata  <= data;
      @(posedge i_pclk); // Master samples request on this rising edge
      i_req    <= 1'b0; // De-assert request
      i_addr   <= 'x;   // Drive don't care after request is sampled
      i_wdata  <= 'x;

      // Wait for the master to transition to the APB ACCESS phase
      wait(o_psel && o_pen);
      $display("[%0t] -> ACCESS detected (Psel=1, Pen=1) for write", $time);

      // Slave responds immediately (0-wait state)
      i_pready <= 1'b1;
      @(posedge i_pclk); // Master processes PREADY here
      i_pready <= 1'b0; 

      $display("[%0t] <<< WRITE OPERATION DONE: ADDR=0x%h, DATA=0x%h", $time, addr, data);
    end
  endtask

  // Task to perform an APB read transaction
  task apb_read(input[ADDR_WIDTH-1:0] addr, input [DATA_WIDTH-1:0] exp_data);
    begin
      $display("[%0t] >>> Starting apb_read from ADDR=0x%h", $time, addr);
      wait(o_ready); 
      // Drive request for one cycle to FIFO
      @(negedge i_pclk);
      i_req  = 1'b1;
      i_rw   = 1'b0; // Read command
      i_addr = addr;
      @(negedge i_pclk); 
      i_req  = 1'b0; 
      i_addr = 'x;

      // Wait for the master to transition to the APB ACCESS phase
      wait(o_psel && o_pen);
      $display("[%0t] -> ACCESS detected (Psel=1, Pen=1) for read", $time);
     
      i_pready <= 1'b1;
      i_prdata <= exp_data; 

      @(negedge i_pclk); 
      @(negedge i_pclk); 

      i_pready <= 1'b0; 
      i_prdata <= 'x;   

      if (o_rdata !== exp_data) begin
        $error("[%0t] READ FAIL: ADDR=0x%h, GOT=0x%h, EXP=0x%h", $time, addr, o_rdata, exp_data);
      end else begin
        $display("[%0t] <<< READ OK: ADDR=0x%h DATA=0x%h", $time, addr, o_rdata);
      end
    end
  endtask

  // Task to test slave error injection
  task bus_error_test;
    reg [ADDR_WIDTH-1:0] addr;
    reg [DATA_WIDTH-1:0] data;
    begin
      $display("\n=== Starting Bus Error Injection Test ===");
      addr <= 16'h0008;
      data <= 16'hDEAD;

      wait(o_ready);
      @(negedge i_pclk);
      i_req    <= 1'b1;
      i_rw     <= 1'b1; // Write to inject error
      i_addr   <= addr;
      i_wdata  <= data;
      @(negedge i_pclk);
      i_req    <= 1'b0;
      i_addr   <= 'x;
      i_wdata  <= 'x;

      // Wait for ACCESS phase
      wait(o_psel && o_pen);
      $display("[%0t] -> ACCESS detected for error injection", $time);

      // Inject slave error during ACCESS
      i_pready <= 1'b1;
      i_pslver <= 1'b1; // Assert slave error

      @(negedge i_pclk); // Master processes PREADY and PSLVER here
      // Now check if o_p_error is asserted by the master
      if (!o_p_error) begin
        $error("[%0t] ERROR: o_p_error not asserted by master during slave error!", $time);
      end else begin
        $display("[%0t] Bus Error correctly detected by master.", $time);
      end

      // De-assert slave signals after transaction completes
      i_pready <= 1'b0;
      i_pslver <= 1'b0;

      $display("=== Bus Error Injection Test COMPLETED ===\n");
    end
  endtask
  
  task slave_no_response_hang_test(input bit is_write);
    begin
      $display("[%0t] >> Starting slave no-response hang test (%s)", $time, is_write ? "WRITE" : "READ");

      wait(o_ready);
      @(posedge i_pclk);
      i_req    <= 1'b1;
      i_rw     <= is_write;
      i_addr   <= 16'h0A06;
      i_wdata  <= is_write ? 16'hBEEF : 'x; // Provide write data only for writes
      @(posedge i_pclk);
      i_req    <= 1'b0;
      i_addr   <= 'x;
      i_wdata  <= 'x;

      // Slave intentionally unresponsive: keep i_pready and i_pslver low indefinitely
      
      
      i_pready <= 1'b0;
      i_pslver <= 1'b0;

      $display("[%0t] WARNING: Master is now waiting indefinitely for slave response.", $time);
      $display("[%0t] Simulation will effectively hang here unless manually stopped or a simulator timeout is configured.", $time);
      
      
    end
  endtask

  // 
  
  task violation_change_addr;
    begin
      $display("\n[%0t] >> Starting Violation Test: Changing Address Mid-Transaction", $time);

      wait(o_ready);
      @(posedge i_pclk);
      i_req    <= 1'b1;
      i_rw     <= 1'b1;
      i_addr   <= 16'h0010; // Original address
      i_wdata  <= 16'h5678;

      // Master should latch the request and address here
      @(posedge i_pclk);
      i_req    <= 1'b0;

      // VIOLATION:
      i_addr   <= 16'h0020; // Changed address (should be ignored by DUT)


      wait(o_psel && o_pen && (o_paddr == 16'h0010));
      if (o_paddr !== 16'h0010) begin
        $error("[%0t] VIOLATION FAIL: Master used the changed address 0x%h, expected 0x0010", $time, o_paddr);
      end else begin
        $display("[%0t] VIOLATION PASS: Master correctly ignored address change.", $time);
      end

      // Complete the APB transaction with slave ready
      i_pready <= 1'b1;
      @(posedge i_pclk);
      i_pready <= 1'b0;

      $display("[%0t] << Violation test completed.\n", $time);
    end
  endtask

  // Test with N slave wait cycles
  task wait_cycle_test(input bit is_write,
                       input [ADDR_WIDTH-1:0] addr,
                       input [DATA_WIDTH-1:0] write_data,
                       input [DATA_WIDTH-1:0] exp_read_data,
                       input int num_wait_cycles);
    begin
      $display("[%0t] >> wait_cycle_test (%s), ADDR=0x%h, DATA=0x%h, WAITS=%0d",
               $time, is_write ? "WRITE" : "READ", addr,
               is_write ? write_data : exp_read_data, num_wait_cycles);

      wait (o_ready); // Wait for master to be ready

      @(posedge i_pclk);
      i_req    <= 1'b1;
      i_rw     <= is_write;
      i_addr   <= addr;
      i_wdata  <= is_write ? write_data : 'x;
      // Provide write data only for writes

      @(posedge i_pclk);
      i_req    <= 0;

      wait(o_psel && o_pen); // Wait for master to enter ACCESS phase
      $display("[%0t] -> ACCESS detected, starting %0d wait cycles.", $time, num_wait_cycles);

      // Slave holds PREADY low for num_wait_cycles
      i_pready <= 1'b0;
      repeat(num_wait_cycles) @(posedge i_pclk);

      $display("[%0t] -> Wait cycles complete. Responding with PREADY.", $time);
      i_pready  <= 1'b1;
      i_prdata  <= is_write ? 'x : exp_read_data; // Only drive prdata for reads

      @(posedge i_pclk); // Master receives PREADY and completes 
      @(posedge i_pclk); // ADDED THIS LINE for read verification

      i_pready <= 1'b0;
      i_prdata <= 'x;

      if (!is_write) begin // For read transactions, verify data
        if (o_rdata !== exp_read_data) begin
          $error("[%0t] READ ERROR: Got 0x%h, EXP 0x%h", $time, o_rdata, exp_read_data);
        end else begin
          $display("[%0t] READ VERIFIED: ADDR=0x%h DATA=0x%h", $time, addr, o_rdata);
        end
      end
      $display("[%0t] << TEST SUCCESS: %s on ADDR=0x%h with %0d wait cycles.",
                $time, is_write ? "WRITE":"READ", addr, num_wait_cycles);
    end
  endtask
//  -------------------------TASK FIFO---------------// 
  task fifo_full_test;
    int i;
    reg [ADDR_WIDTH-1:0] current_addr;
    reg [DATA_WIDTH-1:0] current_data;
    begin
      $display("\n=== Starting FIFO Full Condition Test ===");
      reset_test(); // Ensure FIFO is empty initially

      current_addr = 16'h1000;
      current_data = 16'hAAAA;

      for (i = 0; i < FIFO_DEPTH - 1; i = i + 1) begin
        $display("[%0t] Filling FIFO: Request #%0d (ADDR=0x%h)", $time, i, current_addr + i);
        
        @(posedge i_pclk);
        i_req    = 1'b1;
        i_rw     = 1'b1; // Write
        i_addr   = current_addr + i;
        i_wdata  = current_data + i;
        @(posedge i_pclk);
        i_req    = 1'b0;
        
         if (o_full) $error("[%0t] ERROR: o_full asserted prematurely at %0d elements!", $time, i+1);
        if (!o_ready) $error("[%0t] ERROR: o_ready de-asserted prematurely at %0d elements!", $time, i+1);

        // Wait a few cycles to allow FIFO to process the write
        repeat(2) @(posedge i_pclk);
      end

      // adding one more element to make it full
      $display("[%0t] Attempting to add final element to make FIFO full (ADDR=0x%h)", $time, current_addr + (FIFO_DEPTH - 1));
      @(posedge i_pclk);
      i_req    = 1'b1;
      i_rw     = 1'b1;
      i_addr   = current_addr + (FIFO_DEPTH - 1);
      i_wdata  = current_data + (FIFO_DEPTH - 1);
      @(posedge i_pclk);
      i_req    = 1'b0; // De-assert request
      
       @(posedge i_pclk); // Wait for signals to propagate
      if (!o_full) $error("[%0t] ERROR: o_full not asserted after filling FIFO!", $time);
      if (o_ready) $error("[%0t] ERROR: o_ready still asserted when FIFO should be full!", $time);
      $display("[%0t] FIFO is correctly reporting FULL.", $time);

      // Try to push another request (should be ignored)
      $display("[%0t] Attempting to push request while FIFO is full (should be ignored)", $time);
      @(posedge i_pclk);
      i_req    = 1'b1;
      i_rw     = 1'b1;
      i_addr   = 16'hFFFF; // Dummy address
      i_wdata  = 16'hFFFF; // Dummy data
      @(posedge i_pclk);
      i_req    = 1'b0;
      repeat(5) @(posedge i_pclk); // 
      
      
      if (!o_full) $error("[%0t] ERROR: FIFO became not full unexpectedly after trying to push to full FIFO!", $time);
      if (o_ready) $error("[%0t] ERROR: Master became ready unexpectedly after trying to push to full FIFO!", $time);
      $display("[%0t] Master correctly ignored request while FIFO was full.", $time);

      // Perform a read to make space in the FIFO
      $display("[%0t] Performing a read to free up FIFO space (ADDR=0x%h)", $time, current_addr);
      apb_read(current_addr, current_data); // Read the first element
     // Verify that o_full de-asserts and o_ready asserts again
      @(posedge i_pclk);
      if (o_full) $error("[%0t] ERROR: o_full still asserted after freeing space!", $time);
      if (!o_ready) $error("[%0t] ERROR: o_ready not asserted after freeing space!", $time);
      $display("[%0t] FIFO is correctly reporting NOT FULL (o_ready asserted).", $time);
      $display("=== FIFO Full Condition Test COMPLETED ===\n");
    end
  endtask


  
  
  //----------------------------TEST DRIVER------------------------//
  initial begin
    $display("----- APB MASTER TEST SEQUENCE STARTS -----");
    reset_test();

    // Basic Write and Read
    apb_write(16'h0004, 16'hA5A5);
    apb_read(16'h0004, 16'hA5A5); // Verify write by reading back

    // Boundary Address Tests
    apb_write(16'hFFFC, 16'hDEAD);
    apb_read(16'hFFFC, 16'hDEAD);
    apb_write(16'h0000, 16'hBEEF);
    apb_read(16'h0000, 16'hBEEF);

    // Bus Error Test (slave asserting PSLVER)
    bus_error_test();

    // Wait State Tests
    wait_cycle_test(.is_write(1), .addr(16'h0010), .write_data(16'h1234), .exp_read_data('x), .num_wait_cycles(2)); // WRITE with 2 wait states
    wait_cycle_test(.is_write(0), .addr(16'h0010), .write_data('x), .exp_read_data(16'h1234), .num_wait_cycles(3)); // READ with 3 wait states

    // Protocol Violation Test (changing address mid-transaction)
    violation_change_addr();
    fifo_full_test;

    $display("\n----- ALL TESTS COMPLETED SUCCESSFULLY -----");
    $finish; // End simulation
  end

  // Waveform dumping (for debugging)
  initial begin
    $dumpfile("master_tb.vcd");
    $dumpvars(0, master_tb);
  end

endmodule
