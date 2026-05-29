----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date: 2026/03/21
-- Design Name: ALU with Multiplier IP Core
-- Module Name: alu
-- Project Name: MIPS CPU Lab1
-- Target Devices: Xilinx FPGA
-- Tool Versions: Vivado 2026.1
-- Description: ALU supporting all Loongson C1C2C3 instructions with IP core multiplier
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity alu is
    Port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        a        : in  std_logic_vector(31 downto 0); -- alu_a_val
        b        : in  std_logic_vector(31 downto 0); -- alu_b_val
        alu_type : in  std_logic_vector(3 downto 0);  -- idex_alu_type
        valid    : in  std_logic;                     -- idex_v
        ex_stall : in  std_logic;                     -- pipeline stall signal
        mem_stall: in  std_logic;                     -- freeze state machine during memory stall

        -- Output
        out_res  : out std_logic_vector(31 downto 0); -- ex_alu_out 
        alu_stall: out std_logic;                     -- ALU stall for multi-cycle operations

        -- Branch control
        br_type  : in  std_logic_vector(3 downto 0);  -- idex_br_type
        pc       : in  std_logic_vector(31 downto 0); -- idex_pc
        rs_v     : in  std_logic_vector(31 downto 0); -- idex_rs_val
        imm      : in  std_logic_vector(31 downto 0); -- idex_imm
        jump     : out std_logic;                     -- jump taken
        branch   : out std_logic_vector(31 downto 0)  -- branch target address
    );
end alu;

architecture Behavioral of alu is

    -- Multiplier IP core component declaration
    COMPONENT mult_gen_0
        PORT (
            CLK : IN STD_LOGIC;
            A   : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            B   : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
            P   : OUT STD_LOGIC_VECTOR(63 DOWNTO 0)
        );
    END COMPONENT;

    -- Multiplier signals
    signal mult_a     : std_logic_vector(31 downto 0);
    signal mult_b     : std_logic_vector(31 downto 0);
    signal mult_p     : std_logic_vector(63 downto 0);
    signal mult_neg   : std_logic;
    -- ALU state machine for multi-cycle operations
    type alu_state_type is (IDLE, LOAD_IP, MULTIPLYING, WRITEBACK);
    signal alu_state : alu_state_type;

    -- Internal result signals
    signal comb_result : std_logic_vector(31 downto 0); -- Combinational result
    signal mult_result : std_logic_vector(31 downto 0); -- Registered multiplier result

begin

    -- Instantiate multiplier IP core
    multiplier_inst : mult_gen_0
        PORT MAP (
            CLK => clk,
            A   => mult_a,
            B   => mult_b,
            P   => mult_p
        );

    -- ========================================================
    -- ALU State Machine for Multi-cycle Operations
    -- ========================================================
    process(clk, rst)
    begin
        if rst = '1' then
            alu_state <= IDLE;
            mult_a <= (others => '0');
            mult_b <= (others => '0');
            mult_result <= (others => '0');
            mult_neg <= '0';
        elsif rising_edge(clk) then
            if mem_stall = '1' then
                null; -- freeze during memory stall
            else
            case alu_state is
                when IDLE =>
                    if valid = '1' and alu_type = "1100" then
                        -- Start signed MUL on unsigned multiplier IP:
                        -- feed absolute values, remember sign to restore later.
                        if a(31) = '1' then
                            mult_a <= std_logic_vector(unsigned(not a) + 1);
                        else
                            mult_a <= a;
                        end if;
                        if b(31) = '1' then
                            mult_b <= std_logic_vector(unsigned(not b) + 1);
                        else
                            mult_b <= b;
                        end if;
                        mult_neg <= a(31) xor b(31);
                        -- mult_a/mult_b are registered now; IP samples them on next clock.
                        alu_state <= LOAD_IP;
                    end if;

                when LOAD_IP =>
                    -- Wait one cycle for IP input sampling.
                    alu_state <= MULTIPLYING;

                when MULTIPLYING =>
                    -- Latch signed-restored low 32-bit result from IP.
                    if mult_neg = '1' then
                        mult_result <= std_logic_vector(unsigned(not mult_p(31 downto 0)) + 1);
                    else
                        mult_result <= mult_p(31 downto 0);
                    end if;
                    alu_state <= WRITEBACK;

                when WRITEBACK =>
                    -- Keep result stable for one non-stall cycle for EX/MEM sampling
                    alu_state <= IDLE;

                when others =>
                    alu_state <= IDLE;
            end case;
            end if;
        end if;
    end process;

    -- ALU stall signal: stall pipeline during multiplication
    -- Stall immediately when MUL enters EX, and while waiting multiplier result.
    alu_stall <= '1' when ((alu_state = IDLE and valid = '1' and alu_type = "1100") or
                           (alu_state = LOAD_IP) or
                           (alu_state = MULTIPLYING))
                 else '0';

    -- ========================================================
    -- 1. Combinational ALU Operations
    -- ========================================================
    process(a, b, alu_type, pc, br_type)
    begin
        case alu_type is
            when "0000" => comb_result <= std_logic_vector(unsigned(a) + unsigned(b)); -- ADD/ADDU
            when "0001" => comb_result <= std_logic_vector(unsigned(a) - unsigned(b)); -- SUB
            when "0010" => -- SLT
                if signed(a) < signed(b) then comb_result <= X"00000001";
                else comb_result <= X"00000000"; end if;
            when "0011" => -- SLTU
                if unsigned(a) < unsigned(b) then comb_result <= X"00000001";
                else comb_result <= X"00000000"; end if;
            when "0100" => comb_result <= a and b;                                     -- AND
            when "0101" => comb_result <= a or b;                                      -- OR
            when "0110" => comb_result <= a xor b;                                     -- XOR
            when "0111" => comb_result <= b;                                           -- LUI
            when "1000" => comb_result <= std_logic_vector(shift_left(unsigned(b), to_integer(unsigned(a(4 downto 0))))); -- SLL
            when "1001" => comb_result <= std_logic_vector(shift_right(unsigned(b), to_integer(unsigned(a(4 downto 0))))); -- SRL
            when "1010" => comb_result <= std_logic_vector(shift_right(signed(b), to_integer(unsigned(a(4 downto 0)))));   -- SRA
            when "1011" => comb_result <= b;                                           -- RS2 (pass second operand)
            when "1100" => comb_result <= mult_result;                                 -- MUL (use multiplier result)
            when "1111" => -- JAL/JALR return address is PC+8
                comb_result <= std_logic_vector(unsigned(pc) + 8);
            when others =>
                comb_result <= (others => '0');
        end case;
    end process;

    -- Output result selection
    out_res <= mult_result when (alu_type = "1100") else comb_result;

    -- ========================================================
    -- 2. Branch/jump evaluation (combinational: jump, branch)
    -- ========================================================
    process(br_type, a, b, rs_v, pc, imm)
        variable is_jump_v : std_logic;
        variable target_v  : std_logic_vector(31 downto 0);
    begin
        is_jump_v := '0';
        target_v  := (others => '0');

        case br_type is
            when "0000" => -- BEQ
                if a = b then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0001" => -- BNE
                if a /= b then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0010" => -- BGEZ
                if signed(a) >= 0 then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0011" => -- BGTZ
                if signed(a) > 0 then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0100" => -- BLEZ
                if signed(a) <= 0 then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0101" => -- BLTZ
                if signed(a) < 0 then is_jump_v := '1'; end if;
                target_v := std_logic_vector(unsigned(pc) + unsigned(imm(29 downto 0) & "00") + 4);

            when "0110" => -- J
                is_jump_v := '1';
                target_v  := std_logic_vector(unsigned(pc) + 4)(31 downto 28) & imm(25 downto 0) & "00";

            when "0111" => -- JAL
                is_jump_v := '1';
                target_v  := std_logic_vector(unsigned(pc) + 4)(31 downto 28) & imm(25 downto 0) & "00";

            when "1000" => -- JR
                is_jump_v := '1';
                target_v  := a; -- rs_v

            when "1001" => -- JALR
                is_jump_v := '1';
                target_v  := a; -- rs_v

            when others =>
                is_jump_v := '0';
                target_v  := (others => '0');
        end case;

        jump   <= is_jump_v;
        branch <= target_v;
    end process;

end Behavioral;
