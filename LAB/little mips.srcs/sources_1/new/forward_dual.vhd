library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Dual-lane forwarding + hazard detection (Lab5).
-- Each lane forwards from its own EX/MEM and from the sibling lane EX/MEM.
entity forward_dual is
    Port (
        -- Lane0 (slot0 / master) ID operands
        id0_rs, id0_rt       : in  std_logic_vector(4 downto 0);
        id0_rs_val, id0_rt_val : in  std_logic_vector(31 downto 0);
        id0_use_rs, id0_use_rt : in  std_logic;
        id0_v                : in  std_logic;

        -- Lane1 (slot1 / slave) ID operands
        id1_rs, id1_rt       : in  std_logic_vector(4 downto 0);
        id1_rs_val, id1_rt_val : in  std_logic_vector(31 downto 0);
        id1_use_rs, id1_use_rt : in  std_logic;
        id1_v                : in  std_logic;

        -- Lane0 EX/MEM
        ex0_v, ex0_reg_w, ex0_datatoreg : in std_logic;
        ex0_rd                           : in std_logic_vector(4 downto 0);
        ex0_alu_out                      : in std_logic_vector(31 downto 0);
        mem0_v, mem0_reg_w, mem0_datatoreg : in std_logic;
        mem0_rd                            : in std_logic_vector(4 downto 0);
        mem0_alu_out                         : in std_logic_vector(31 downto 0);
        dmem0_rdata                          : in std_logic_vector(31 downto 0);

        -- Lane1 EX/MEM
        ex1_v, ex1_reg_w, ex1_datatoreg : in std_logic;
        ex1_rd                           : in std_logic_vector(4 downto 0);
        ex1_alu_out                      : in std_logic_vector(31 downto 0);
        mem1_v, mem1_reg_w, mem1_datatoreg : in std_logic;
        mem1_rd                            : in std_logic_vector(4 downto 0);
        mem1_alu_out                         : in std_logic_vector(31 downto 0);
        dmem1_rdata                          : in std_logic_vector(31 downto 0);

        id0_rs_val_f, id0_rt_val_f : out std_logic_vector(31 downto 0);
        id1_rs_val_f, id1_rt_val_f : out std_logic_vector(31 downto 0);
        id0_data_stall, id1_data_stall : out std_logic
    );
end forward_dual;

architecture Behavioral of forward_dual is

    procedure forward_rs(
        id_rs       : in  std_logic_vector(4 downto 0);
        id_rs_val   : in  std_logic_vector(31 downto 0);
        id_use_rs   : in  std_logic;
        ex0_v       : in  std_logic; ex0_reg_w : in  std_logic; ex0_rd : in  std_logic_vector(4 downto 0);
        ex0_datatoreg : in std_logic; ex0_alu_out : in std_logic_vector(31 downto 0);
        ex1_v       : in  std_logic; ex1_reg_w : in  std_logic; ex1_rd : in  std_logic_vector(4 downto 0);
        ex1_datatoreg : in std_logic; ex1_alu_out : in std_logic_vector(31 downto 0);
        mem0_v      : in  std_logic; mem0_reg_w : in  std_logic; mem0_rd : in  std_logic_vector(4 downto 0);
        mem0_datatoreg : in std_logic; mem0_alu_out : in std_logic_vector(31 downto 0); dmem0_rdata : in std_logic_vector(31 downto 0);
        mem1_v      : in  std_logic; mem1_reg_w : in  std_logic; mem1_rd : in  std_logic_vector(4 downto 0);
        mem1_datatoreg : in std_logic; mem1_alu_out : in std_logic_vector(31 downto 0); dmem1_rdata : in std_logic_vector(31 downto 0);
        id_rs_val_f : out std_logic_vector(31 downto 0)
    ) is
    begin
        id_rs_val_f := id_rs_val;
        if (id_use_rs = '1' and id_rs /= "00000") then
            if (ex0_v = '1' and ex0_reg_w = '1' and ex0_rd = id_rs and ex0_datatoreg = '0') then
                id_rs_val_f := ex0_alu_out;
            elsif (ex1_v = '1' and ex1_reg_w = '1' and ex1_rd = id_rs and ex1_datatoreg = '0') then
                id_rs_val_f := ex1_alu_out;
            elsif (mem0_v = '1' and mem0_reg_w = '1' and mem0_rd = id_rs) then
                if (mem0_datatoreg = '1') then id_rs_val_f := dmem0_rdata; else id_rs_val_f := mem0_alu_out; end if;
            elsif (mem1_v = '1' and mem1_reg_w = '1' and mem1_rd = id_rs) then
                if (mem1_datatoreg = '1') then id_rs_val_f := dmem1_rdata; else id_rs_val_f := mem1_alu_out; end if;
            end if;
        end if;
    end procedure;

    procedure forward_rt(
        id_rt       : in  std_logic_vector(4 downto 0);
        id_rt_val   : in  std_logic_vector(31 downto 0);
        id_use_rt   : in  std_logic;
        ex0_v       : in  std_logic; ex0_reg_w : in  std_logic; ex0_rd : in  std_logic_vector(4 downto 0);
        ex0_datatoreg : in std_logic; ex0_alu_out : in std_logic_vector(31 downto 0);
        ex1_v       : in  std_logic; ex1_reg_w : in  std_logic; ex1_rd : in std_logic_vector(4 downto 0);
        ex1_datatoreg : in std_logic; ex1_alu_out : in std_logic_vector(31 downto 0);
        mem0_v      : in  std_logic; mem0_reg_w : in  std_logic; mem0_rd : in  std_logic_vector(4 downto 0);
        mem0_datatoreg : in std_logic; mem0_alu_out : in std_logic_vector(31 downto 0); dmem0_rdata : in std_logic_vector(31 downto 0);
        mem1_v      : in  std_logic; mem1_reg_w : in  std_logic; mem1_rd : in std_logic_vector(4 downto 0);
        mem1_datatoreg : in std_logic; mem1_alu_out : in std_logic_vector(31 downto 0); dmem1_rdata : in std_logic_vector(31 downto 0);
        id_rt_val_f : out std_logic_vector(31 downto 0)
    ) is
    begin
        id_rt_val_f := id_rt_val;
        if (id_use_rt = '1' and id_rt /= "00000") then
            if (ex0_v = '1' and ex0_reg_w = '1' and ex0_rd = id_rt and ex0_datatoreg = '0') then
                id_rt_val_f := ex0_alu_out;
            elsif (ex1_v = '1' and ex1_reg_w = '1' and ex1_rd = id_rt and ex1_datatoreg = '0') then
                id_rt_val_f := ex1_alu_out;
            elsif (mem0_v = '1' and mem0_reg_w = '1' and mem0_rd = id_rt) then
                if (mem0_datatoreg = '1') then id_rt_val_f := dmem0_rdata; else id_rt_val_f := mem0_alu_out; end if;
            elsif (mem1_v = '1' and mem1_reg_w = '1' and mem1_rd = id_rt) then
                if (mem1_datatoreg = '1') then id_rt_val_f := dmem1_rdata; else id_rt_val_f := mem1_alu_out; end if;
            end if;
        end if;
    end procedure;

    procedure load_use(
        id_rs, id_rt : in std_logic_vector(4 downto 0);
        id_use_rs, id_use_rt, id_v : in std_logic;
        ex_v, ex_datatoreg : in std_logic;
        ex_rd : in std_logic_vector(4 downto 0);
        stall : out std_logic
    ) is
    begin
        stall := '0';
        if (id_v = '1' and ex_v = '1' and ex_datatoreg = '1' and ex_rd /= "00000") then
            if ((id_use_rs = '1' and ex_rd = id_rs) or (id_use_rt = '1' and ex_rd = id_rt)) then
                stall := '1';
            end if;
        end if;
    end procedure;

begin
    process(id0_rs, id0_rt, id0_rs_val, id0_rt_val, id0_use_rs, id0_use_rt, id0_v,
            id1_rs, id1_rt, id1_rs_val, id1_rt_val, id1_use_rs, id1_use_rt, id1_v,
            ex0_v, ex0_rd, ex0_reg_w, ex0_alu_out, ex0_datatoreg,
            ex1_v, ex1_rd, ex1_reg_w, ex1_alu_out, ex1_datatoreg,
            mem0_v, mem0_rd, mem0_reg_w, mem0_alu_out, mem0_datatoreg, dmem0_rdata,
            mem1_v, mem1_rd, mem1_reg_w, mem1_alu_out, mem1_datatoreg, dmem1_rdata)
    begin
        forward_rs(id0_rs, id0_rs_val, id0_use_rs,
            ex0_v, ex0_reg_w, ex0_rd, ex0_datatoreg, ex0_alu_out,
            ex1_v, ex1_reg_w, ex1_rd, ex1_datatoreg, ex1_alu_out,
            mem0_v, mem0_reg_w, mem0_rd, mem0_datatoreg, mem0_alu_out, dmem0_rdata,
            mem1_v, mem1_reg_w, mem1_rd, mem1_datatoreg, mem1_alu_out, dmem1_rdata,
            id0_rs_val_f);
        forward_rt(id0_rt, id0_rt_val, id0_use_rt,
            ex0_v, ex0_reg_w, ex0_rd, ex0_datatoreg, ex0_alu_out,
            ex1_v, ex1_reg_w, ex1_rd, ex1_datatoreg, ex1_alu_out,
            mem0_v, mem0_reg_w, mem0_rd, mem0_datatoreg, mem0_alu_out, dmem0_rdata,
            mem1_v, mem1_reg_w, mem1_rd, mem1_datatoreg, mem1_alu_out, dmem1_rdata,
            id0_rt_val_f);

        forward_rs(id1_rs, id1_rs_val, id1_use_rs,
            ex0_v, ex0_reg_w, ex0_rd, ex0_datatoreg, ex0_alu_out,
            ex1_v, ex1_reg_w, ex1_rd, ex1_datatoreg, ex1_alu_out,
            mem0_v, mem0_reg_w, mem0_rd, mem0_datatoreg, mem0_alu_out, dmem0_rdata,
            mem1_v, mem1_reg_w, mem1_rd, mem1_datatoreg, mem1_alu_out, dmem1_rdata,
            id1_rs_val_f);
        forward_rt(id1_rt, id1_rt_val, id1_use_rt,
            ex0_v, ex0_reg_w, ex0_rd, ex0_datatoreg, ex0_alu_out,
            ex1_v, ex1_reg_w, ex1_rd, ex1_datatoreg, ex1_alu_out,
            mem0_v, mem0_reg_w, mem0_rd, mem0_datatoreg, mem0_alu_out, dmem0_rdata,
            mem1_v, mem1_reg_w, mem1_rd, mem1_datatoreg, mem1_alu_out, dmem1_rdata,
            id1_rt_val_f);

        load_use(id0_rs, id0_rt, id0_use_rs, id0_use_rt, id0_v,
                 ex0_v, ex0_datatoreg, ex0_rd, id0_data_stall);
        load_use(id1_rs, id1_rt, id1_use_rs, id1_use_rt, id1_v,
                 ex0_v, ex0_datatoreg, ex0_rd, id1_data_stall);
        if (id1_data_stall = '0') then
            load_use(id1_rs, id1_rt, id1_use_rs, id1_use_rt, id1_v,
                     ex1_v, ex1_datatoreg, ex1_rd, id1_data_stall);
        end if;
    end process;
end Behavioral;
