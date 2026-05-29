library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity forward is
    Port (
        -- ID stage: current instruction's register info
        id_rs         : in  std_logic_vector(4 downto 0);
        id_rt         : in  std_logic_vector(4 downto 0);
        id_rs_val     : in  std_logic_vector(31 downto 0); -- raw register file value for rs
        id_rt_val     : in  std_logic_vector(31 downto 0); -- raw register file value for rt
        id_use_rs     : in  std_logic; -- whether this instruction uses rs
        id_use_rt     : in  std_logic; -- whether this instruction uses rt

        -- EX stage: previous instruction info (1 cycle ahead)
        ex_v          : in  std_logic; -- instruction valid
        ex_rd         : in  std_logic_vector(4 downto 0); -- destination register
        ex_reg_w      : in  std_logic; -- whether this instruction writes a register
        ex_alu_out    : in  std_logic_vector(31 downto 0); -- ALU result
        ex_datatoreg  : in  std_logic; -- whether this is a LW instruction

        -- MEM stage: two-instructions-ago info (2 cycles ahead)
        mem_v         : in  std_logic;
        mem_rd        : in  std_logic_vector(4 downto 0);
        mem_reg_w     : in  std_logic;
        mem_alu_out   : in  std_logic_vector(31 downto 0);
        mem_datatoreg : in  std_logic;
        dmem_rdata    : in  std_logic_vector(31 downto 0); -- data just read from memory

        -- Forwarded operand values and stall signal
        id_rs_val_f   : out std_logic_vector(31 downto 0);
        id_rt_val_f   : out std_logic_vector(31 downto 0);
        id_data_stall : out std_logic -- load-use hazard stall
    );
end forward;

architecture Behavioral of forward is
begin
    process(id_rs, id_rt, id_rs_val, id_rt_val, id_use_rs, id_use_rt,
            ex_v, ex_rd, ex_reg_w, ex_alu_out, ex_datatoreg,
            mem_v, mem_rd, mem_reg_w, mem_alu_out, mem_datatoreg, dmem_rdata)
    begin
        -- Default: use raw register file values (no forwarding)
        id_rs_val_f <= id_rs_val;
        id_rt_val_f <= id_rt_val;
        id_data_stall <= '0';

        -- ========================================================
        -- 1. RS forwarding (EX checked first, then MEM)
        -- ========================================================
        if (id_use_rs = '1' and id_rs /= "00000") then
            -- Check EX stage (1 instruction ahead)
            if (ex_v = '1' and ex_reg_w = '1' and ex_rd = id_rs) then
                if (ex_datatoreg = '0') then -- not LW, EX result already computed
                    id_rs_val_f <= ex_alu_out;
                else
                    -- LW in EX: data not ready yet, stall handled in section 3 below
                    null;
                end if;
            -- Check MEM stage (2 instructions ahead)
            elsif (mem_v = '1' and mem_reg_w = '1' and mem_rd = id_rs) then
                if (mem_datatoreg = '1') then
                    id_rs_val_f <= dmem_rdata; -- forward memory load data
                else
                    id_rs_val_f <= mem_alu_out; -- forward ALU result
                end if;
            end if;
        end if;

        -- ========================================================
        -- 2. RT forwarding (same logic as RS)
        -- ========================================================
        if (id_use_rt = '1' and id_rt /= "00000") then
            if (ex_v = '1' and ex_reg_w = '1' and ex_rd = id_rt) then
                if (ex_datatoreg = '0') then
                    id_rt_val_f <= ex_alu_out;
                end if;
            elsif (mem_v = '1' and mem_reg_w = '1' and mem_rd = id_rt) then
                if (mem_datatoreg = '1') then
                    id_rt_val_f <= dmem_rdata;
                else
                    id_rt_val_f <= mem_alu_out;
                end if;
            end if;
        end if;

        -- ========================================================
        -- 3. Load-Use Hazard detection (pipeline stall)
        -- ========================================================
        -- If the EX stage instruction is LW and the ID stage
        -- instruction needs that loaded register, we must stall
        -- one cycle so the LW can reach MEM where data is available.
        if (ex_v = '1' and ex_datatoreg = '1' and ex_rd /= "00000") then
            if ((id_use_rs = '1' and ex_rd = id_rs) or
                (id_use_rt = '1' and ex_rd = id_rt)) then
                id_data_stall <= '1'; -- assert pipeline stall
            end if;
        end if;

    end process;
end Behavioral;
