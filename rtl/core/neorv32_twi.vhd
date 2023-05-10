-- #################################################################################################
-- # << NEORV32 - Two-Wire Interface Controller (TWI) >>                                           #
-- # ********************************************************************************************* #
-- # Supports START and STOP conditions, 8 bit data + ACK/NACK transfers and clock stretching.     #
-- # Supports ACKs by the controller. No multi-controller support and no peripheral mode support   #
-- # yet. Interrupt: "transmission done"                                                           #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2022, Stephan Nolting. All rights reserved.                                     #
-- #                                                                                               #
-- # Redistribution and use in source and binary forms, with or without modification, are          #
-- # permitted provided that the following conditions are met:                                     #
-- #                                                                                               #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of        #
-- #    conditions and the following disclaimer.                                                   #
-- #                                                                                               #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
-- #    conditions and the following disclaimer in the documentation and/or other materials        #
-- #    provided with the distribution.                                                            #
-- #                                                                                               #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
-- #    endorse or promote products derived from this software without specific prior written      #
-- #    permission.                                                                                #
-- #                                                                                               #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
-- # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
-- # ********************************************************************************************* #
-- # The NEORV32 Processor - https://github.com/stnolting/neorv32              (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_twi is
  port (
    -- host access --
    clk_i       : in  std_ulogic; -- global clock line
    rstn_i      : in  std_ulogic; -- global reset line, low-active
    addr_i      : in  std_ulogic_vector(31 downto 0); -- address
    rden_i      : in  std_ulogic; -- read enable
    wren_i      : in  std_ulogic; -- write enable
    data_i      : in  std_ulogic_vector(31 downto 0); -- data in
    data_o      : out std_ulogic_vector(31 downto 0); -- data out
    ack_o       : out std_ulogic; -- transfer acknowledge
    -- clock generator --
    clkgen_en_o : out std_ulogic; -- enable clock generator
    clkgen_i    : in  std_ulogic_vector(07 downto 0);
    -- com lines (require external tri-state drivers) --
    twi_sda_i   : in  std_ulogic; -- serial data line input
    twi_sda_o   : out std_ulogic; -- serial data line output
    twi_scl_i   : in  std_ulogic; -- serial clock line input
    twi_scl_o   : out std_ulogic; -- serial clock line output
    -- interrupt --
    irq_o       : out std_ulogic -- transfer done IRQ
  );
end neorv32_twi;

architecture neorv32_twi_rtl of neorv32_twi is

  -- IO space: module base address --
  constant hi_abb_c : natural := index_size_f(io_size_c)-1; -- high address boundary bit
  constant lo_abb_c : natural := index_size_f(twi_size_c); -- low address boundary bit

  -- control register --
  constant ctrl_en_c      : natural := 0; -- r/w: TWI enable
  constant ctrl_start_c   : natural := 1; -- -/w: Generate START condition
  constant ctrl_stop_c    : natural := 2; -- -/w: Generate STOP condition
  constant ctrl_prsc0_c   : natural := 3; -- r/w: CLK prsc bit 0
  constant ctrl_prsc1_c   : natural := 4; -- r/w: CLK prsc bit 1
  constant ctrl_prsc2_c   : natural := 5; -- r/w: CLK prsc bit 2
  constant ctrl_mack_c    : natural := 6; -- r/w: generate ACK by controller for transmission
  --
  constant ctrl_claimed_c : natural := 29; -- r/-: Set if bus is still claimed
  constant ctrl_ack_c     : natural := 30; -- r/-: Set if ACK received
  constant ctrl_busy_c    : natural := 31; -- r/-: Set if TWI unit is busy

  -- access control --
  signal acc_en : std_ulogic; -- module access enable
  signal addr   : std_ulogic_vector(31 downto 0); -- access address
  signal wren   : std_ulogic; -- word write enable
  signal rden   : std_ulogic; -- read enable

  -- control register --
  type ctrl_t is record
    enable : std_ulogic;
    prsc   : std_ulogic_vector(2 downto 0);
    mack   : std_ulogic;
  end record;
  signal ctrl : ctrl_t;

  -- clock generator --
  type clk_gen_t is record
    clk_tick     : std_ulogic;
    clk_tick_ff  : std_ulogic;
    phase_gen    : std_ulogic_vector(3 downto 0);
    phase_gen_ff : std_ulogic_vector(3 downto 0);
    phase        : std_ulogic_vector(3 downto 0);
    halt         : std_ulogic;
  end record;
  signal clk_gen : clk_gen_t;

  -- arbiter --
  type arbiter_t is record
    state     : std_ulogic_vector(2 downto 0);
    state_nxt : std_ulogic_vector(1 downto 0);
    bitcnt    : std_ulogic_vector(3 downto 0);
    rtx_sreg  : std_ulogic_vector(8 downto 0); -- main rx/tx shift reg
    rtx_done  : std_ulogic;
    busy      : std_ulogic;
    claimed   : std_ulogic;
  end record;
  signal arbiter : arbiter_t;

  -- tri-state I/O control --
  type io_con_t is record
    sda_in_ff : std_ulogic_vector(1 downto 0); -- SDA input sync
    scl_in_ff : std_ulogic_vector(1 downto 0); -- SCL input sync
    sda_in    : std_ulogic;
    scl_in    : std_ulogic;
    sda_out   : std_ulogic;
    scl_out   : std_ulogic;
  end record;
  signal io_con : io_con_t;

begin

  -- Access Control -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = twi_base_c(hi_abb_c downto lo_abb_c)) else '0';
  addr   <= twi_base_c(31 downto lo_abb_c) & addr_i(lo_abb_c-1 downto 2) & "00"; -- word aligned
  wren   <= acc_en and wren_i;
  rden   <= acc_en and rden_i;


  -- Read/Write Access ----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  rw_access: process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (rstn_i = '0') then
        ctrl.enable <= '0';
        ctrl.prsc   <= (others => '0');
        ctrl.mack   <= '0';
        ack_o       <= '-';
        data_o      <= (others => '-');
      else
        ack_o <= rden or wren;
        -- write access --
        if (wren = '1') then
          if (addr = twi_ctrl_addr_c) then
            ctrl.enable <= data_i(ctrl_en_c);
            ctrl.prsc   <= data_i(ctrl_prsc2_c downto ctrl_prsc0_c);
            ctrl.mack   <= data_i(ctrl_mack_c);
          end if;
        end if;
        -- read access --
        data_o <= (others => '0');
        if (rden = '1') then
          if (addr = twi_ctrl_addr_c) then
            data_o(ctrl_en_c)                        <= ctrl.enable;
            data_o(ctrl_prsc2_c downto ctrl_prsc0_c) <= ctrl.prsc;
            data_o(ctrl_mack_c)                      <= ctrl.mack;
            --
            data_o(ctrl_claimed_c) <= arbiter.claimed;
            data_o(ctrl_ack_c)     <= not arbiter.rtx_sreg(0);
            data_o(ctrl_busy_c)    <= arbiter.busy;
          else -- twi_rtx_addr_c =>
            data_o(7 downto 0) <= arbiter.rtx_sreg(8 downto 1);
          end if;
        end if;
      end if;
    end if;
  end process rw_access;


  -- Clock Generation -----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- clock generator enable --
  clkgen_en_o <= ctrl.enable;

  -- twi clock select --
  clk_gen.clk_tick <= clkgen_i(to_integer(unsigned(ctrl.prsc)));

  -- generate four non-overlapping clock ticks --
  clock_generator: process(clk_i)
  begin
    if rising_edge(clk_i) then
      clk_gen.clk_tick_ff  <= clk_gen.clk_tick;
      clk_gen.phase_gen_ff <= clk_gen.phase_gen;
      if (arbiter.state(2) = '0') or (arbiter.state(1 downto 0) = "00") then -- offline or idle
        clk_gen.phase_gen <= "0001"; -- make sure to start with a new phase, bit stepping: 0-1-2-3
      else
        if (clk_gen.clk_tick_ff = '1') and (clk_gen.halt = '0') then -- clock tick and no clock stretching detected
          clk_gen.phase_gen <= clk_gen.phase_gen(2 downto 0) & clk_gen.phase_gen(3); -- rotate left
        end if;
      end if;
    end if;
  end process clock_generator;

  -- TWI bus signals are set/sampled using 4 clock phases --
  clk_gen.phase(0) <= clk_gen.phase_gen_ff(0) and (not clk_gen.phase_gen(0)); -- first step
  clk_gen.phase(1) <= clk_gen.phase_gen_ff(1) and (not clk_gen.phase_gen(1));
  clk_gen.phase(2) <= clk_gen.phase_gen_ff(2) and (not clk_gen.phase_gen(2));
  clk_gen.phase(3) <= clk_gen.phase_gen_ff(3) and (not clk_gen.phase_gen(3)); -- last step

  -- Clock Stretching Detector --
  -- controller wants to pull SCL high, but SCL is pulled low by peripheral --
  clk_gen.halt <= '1' when (io_con.scl_out = '1') and (io_con.scl_in_ff(1) = '0') else '0';


  -- TWI Transceiver ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  twi_engine: process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- input synchronizer --
      io_con.sda_in_ff <= io_con.sda_in_ff(0) & io_con.sda_in;
      io_con.scl_in_ff <= io_con.scl_in_ff(0) & io_con.scl_in;

      -- interrupt --
      if (arbiter.state = "111") and (arbiter.rtx_done = '1') then -- transmission done
        irq_o <= '1';
      else
        irq_o <= '0';
      end if;

      -- serial engine --
      arbiter.state(2) <= ctrl.enable; -- module enabled?
      case arbiter.state is

        when "100" => -- IDLE: waiting for operation requests
        -- ------------------------------------------------------------
          arbiter.bitcnt <= (others => '0');
          if (wren = '1') then
            if (addr = twi_ctrl_addr_c) then
              if (data_i(ctrl_start_c) = '1') then -- issue START condition
                arbiter.state_nxt <= "01";
              elsif (data_i(ctrl_stop_c) = '1') then  -- issue STOP condition
                arbiter.state_nxt <= "10";
              end if;
            elsif (addr = twi_rtx_addr_c) then -- start a data transmission
              -- one bit extra for ACK: issued by controller if ctrl_mack_c is set,
              -- sampled from peripheral if ctrl_mack_c is cleared
              arbiter.rtx_sreg  <= data_i(7 downto 0) & (not ctrl.mack);
              arbiter.state_nxt <= "11";
            end if;
          end if;
          -- start operation on next TWI clock pulse --
          if (arbiter.state_nxt /= "00") and (clk_gen.clk_tick_ff = '1') then
            arbiter.state(1 downto 0) <= arbiter.state_nxt;
          end if;

        when "101" => -- START: generate (repeated) START condition
        -- ------------------------------------------------------------
          arbiter.state_nxt <= "00"; -- no operation pending anymore
          if (clk_gen.phase(0) = '1') then
            io_con.sda_out <= '1';
          elsif (clk_gen.phase(1) = '1') then
            io_con.sda_out <= '0';
          end if;
          --
          if (clk_gen.phase(0) = '1') then
            io_con.scl_out <= '1';
          elsif (clk_gen.phase(3) = '1') then
            io_con.scl_out <= '0';
            arbiter.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;

        when "110" => -- STOP: generate STOP condition
        -- ------------------------------------------------------------
          arbiter.state_nxt <= "00"; -- no operation pending anymore
          if (clk_gen.phase(0) = '1') then
            io_con.sda_out <= '0';
          elsif (clk_gen.phase(3) = '1') then
            io_con.sda_out <= '1';
            arbiter.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;
          --
          if (clk_gen.phase(0) = '1') then
            io_con.scl_out <= '0';
          elsif (clk_gen.phase(1) = '1') then
            io_con.scl_out <= '1';
          end if;

        when "111" => -- TRANSMISSION: send/receive byte + ACK/NACK/MACK
        -- ------------------------------------------------------------
          arbiter.state_nxt <= "00"; -- no operation pending anymore
          -- SCL clocking --
          if (clk_gen.phase(0) = '1') or (clk_gen.phase(3) = '1') then
            io_con.scl_out <= '0'; -- set SCL low after transmission to keep bus claimed
          elsif (clk_gen.phase(1) = '1') then -- first half + second half of valid data strobe
            io_con.scl_out <= '1';
          end if;
          -- SDA output --
          if (arbiter.rtx_done = '1') then
            io_con.sda_out <= '0'; -- set SDA low after transmission to keep bus claimed
          elsif (clk_gen.phase(0) = '1') then
            io_con.sda_out <= arbiter.rtx_sreg(8); -- MSB first
          end if;
          -- SDA input --
          if (clk_gen.phase(2) = '1') then
            arbiter.rtx_sreg <= arbiter.rtx_sreg(7 downto 0) & io_con.sda_in_ff(1); -- sample SDA input and shift left
          end if;
          -- bit counter --
          if (clk_gen.phase(3) = '1') then
            arbiter.bitcnt <= std_ulogic_vector(unsigned(arbiter.bitcnt) + 1);
          end if;
          -- transmission done --
          if (arbiter.rtx_done = '1') then
            arbiter.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;

        when others => -- "0--" OFFLINE: TWI deactivated, bus unclaimed
        -- ------------------------------------------------------------
          io_con.scl_out            <= '1'; -- SCL driven by pull-up resistor
          io_con.sda_out            <= '1'; -- SDA driven by pull-up resistor
          arbiter.rtx_sreg          <= (others => '0'); -- make DATA and ACK _defined_ after reset
          arbiter.state_nxt         <= "00"; -- no operation pending anymore
          arbiter.state(1 downto 0) <= "00"; -- stay here, go to IDLE when activated

      end case;
    end if;
  end process twi_engine;

  -- transmit 8 data bits + 1 ACK bit and wait for another clock phase --
  arbiter.rtx_done <= '1' when (arbiter.bitcnt = "1001") and (clk_gen.phase(0) = '1') else '0';

  -- arbiter busy? --
  arbiter.busy <= arbiter.state(1) or arbiter.state(0) or -- operation in progress
                  arbiter.state_nxt(1) or arbiter.state_nxt(0); -- pending operation

  -- check if the TWI bus is currently claimed (by this module or any other controller) --
  arbiter.claimed <= '1' when (arbiter.busy = '1') or ((io_con.sda_in_ff(1) = '0') and (io_con.scl_in_ff(1) = '0')) else '0';


  -- Tri-State Driver Interface -------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  twi_sda_o <= io_con.sda_out; -- NOTE: signal lines can only be actively driven low
  twi_scl_o <= io_con.scl_out;
  io_con.sda_in <= twi_sda_i;
  io_con.scl_in <= twi_scl_i;


end neorv32_twi_rtl;
