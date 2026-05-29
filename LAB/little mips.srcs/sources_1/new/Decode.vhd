library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity Decode is
    Port(
        inst       : in std_logic_vector(31 downto 0);
        
        rs              : out std_logic_vector(4 downto 0);
        rt              : out std_logic_vector(4 downto 0);
        rd              : out std_logic_vector(4 downto 0);
        reg_wen         : out std_logic;
        
        imm             : out std_logic_vector(31 downto 0);
        alu_type        : out std_logic_vector(3 downto 0);
        A               : out std_logic_vector(1 downto 0);
        B               : out std_logic_vector(1 downto 0);
        
        dmem_ren        : out std_logic;
        dmem_wen        : out std_logic;
        dmem_use_be     : out std_logic;
        datatoreg       : out std_logic;
        
        br_type         : out std_logic_vector(3 downto 0);
        is_branch_type  : out std_logic;
        use_rs          : out std_logic;
        use_rt          : out std_logic
    );
end Decode;

architecture Behavioral of Decode is
    signal rs_idx : std_logic_vector(4 downto 0);
    signal rt_idx : std_logic_vector(4 downto 0);
    signal rd_idx : std_logic_vector(4 downto 0);
begin
    rs <= rs_idx;
    rt <= rt_idx;
    rd <= rd_idx;
    
    process(inst)
        variable opcode : std_logic_vector(5 downto 0);
        variable funct  : std_logic_vector(5 downto 0);
        variable rt_f   : std_logic_vector(4 downto 0);
    begin
        opcode := inst(31 downto 26);
        funct  := inst(5 downto 0);
        rt_f   := inst(20 downto 16);
        
        -- Extract register indices from instruction
        rs_idx <= inst(25 downto 21);  -- rs field
        rt_idx <= inst(20 downto 16);  -- rt field
        rd_idx <= inst(20 downto 16);  -- default for I-type and most writes

        reg_wen        <= '0';
        alu_type       <= "0000";
        A              <= "00";
        B              <= "00";
        imm            <= (others => '0');
        dmem_ren       <= '0';
        dmem_wen       <= '0';
        dmem_use_be    <= '0';
        datatoreg      <= '0';
        br_type        <= "1010";
        is_branch_type <= '0';
        use_rs         <= '0';
        use_rt         <= '0';
        
        case opcode is
            -- R-type Instructions (Opcode = 000000)
            when "000000" =>
                rs_idx  <= inst(25 downto 21);
                rt_idx  <= inst(20 downto 16);
                rd_idx  <= inst(15 downto 11); -- R-type target rd
                use_rs  <= '1';
                use_rt  <= '1';
                reg_wen <= '1';
                A       <= "00";
                B       <= "00";
                case funct is
                    when "100000" => alu_type <= "0000"; -- ADD
                    when "100001" => alu_type <= "0000"; -- ADDU
                    when "100010" => alu_type <= "0001"; -- SUB
                    when "100011" => alu_type <= "0001"; -- SUBU (Loongson/MIPS32)
                    when "100100" => alu_type <= "0100"; -- AND
                    when "100101" => alu_type <= "0101"; -- OR
                    when "100110" => alu_type <= "0110"; -- XOR
                    when "101010" => alu_type <= "0010"; -- SLT
                    when "101011" => alu_type <= "0011"; -- SLTU
                    when "000000" => -- SLL
                        if inst = X"00000000" then
                            reg_wen <= '0';
                            use_rs  <= '0';
                            use_rt  <= '0';
                        else
                            alu_type <= "1000";
                            A <= "10";
                            use_rs <= '0';
                            imm <= (26 downto 0 => '0') & inst(10 downto 6);
                        end if;
                    when "000010" => -- SRL
                        alu_type <= "1001"; A <= "10"; use_rs <= '0';
                        imm <= (26 downto 0 => '0') & inst(10 downto 6);
                    when "000011" => -- SRA
                        alu_type <= "1010"; A <= "10"; use_rs <= '0';
                        imm <= (26 downto 0 => '0') & inst(10 downto 6);
                    when "000100" => -- SLLV
                        alu_type <= "1000"; use_rs <= '1'; use_rt <= '1';
                    when "000110" => -- SRLV
                        alu_type <= "1001"; use_rs <= '1'; use_rt <= '1';
                    when "000111" => -- SRAV
                        alu_type <= "1010"; use_rs <= '1'; use_rt <= '1';
                    when "001000" => -- JR
                        reg_wen <= '0'; use_rs <= '1'; use_rt <= '0'; is_branch_type <= '1'; br_type <= "1000";
                    when "001001" => -- JALR
                        alu_type <= "1111"; reg_wen <= '1'; use_rs <= '1'; use_rt <= '0'; rd_idx <= inst(15 downto 11); is_branch_type <= '1'; br_type <= "1001";
                    when "011000" => -- MUL
                        alu_type <= "1100"; use_rs <= '1'; use_rt <= '1';
                    when others => reg_wen <= '0';
                end case;

            -- I-type arithmetic
            when "001000" => -- ADDI
                alu_type <= "0000"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "001001" => -- ADDIU
                alu_type <= "0000"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "001101" => -- ORI
                alu_type <= "0101"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( X"0000" & inst(15 downto 0) );
            when "001111" => -- LUI
                alu_type <= "0111"; reg_wen <= '1'; B <= "01";
                imm <= ( inst(15 downto 0) & X"0000" );
            when "001100" => -- ANDI
                alu_type <= "0100"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( X"0000" & inst(15 downto 0) );
            when "001110" => -- XORI
                alu_type <= "0110"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( X"0000" & inst(15 downto 0) );
            when "001010" => -- SLTI
                alu_type <= "0010"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "001011" => -- SLTIU
                alu_type <= "0011"; reg_wen <= '1'; A <= "00"; B <= "01"; use_rs <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );

            -- SPECIAL2 format (opcode = 011100), used by MIPS32 MUL rd, rs, rt
            when "011100" =>
                rs_idx  <= inst(25 downto 21);
                rt_idx  <= inst(20 downto 16);
                rd_idx  <= inst(15 downto 11);
                use_rs  <= '1';
                use_rt  <= '1';
                reg_wen <= '1';
                A       <= "00";
                B       <= "00";
                case funct is
                    when "000010" => -- MUL (SPECIAL2)
                        alu_type <= "1100";
                    when others =>
                        reg_wen <= '0';
                end case;

            -- Memory operations
            when "100011" => -- LW
                alu_type <= "0000"; reg_wen <= '1'; A <= "00"; B <= "01";
                use_rs <= '1'; dmem_ren <= '1'; datatoreg <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "101011" => -- SW
                alu_type <= "0000"; A <= "00"; B <= "01";
                use_rs <= '1'; use_rt <= '1'; dmem_wen <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "100000" => -- LB
                alu_type <= "0000"; reg_wen <= '1'; A <= "00"; B <= "01";
                use_rs <= '1'; dmem_ren <= '1'; datatoreg <= '1'; dmem_use_be <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "101000" => -- SB
                alu_type <= "0000"; A <= "00"; B <= "01";
                use_rs <= '1'; use_rt <= '1'; dmem_wen <= '1'; dmem_use_be <= '1';
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );

            -- Branch and jump
            when "000100" => -- BEQ
                alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1'; use_rt <= '1';
                is_branch_type <= '1'; br_type <= "0000";
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
            when "000101" => -- BNE
                alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1'; use_rt <= '1';
                is_branch_type <= '1'; br_type <= "0001";
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );

            -- REGIMM format
            when "000001" =>
                case rt_f is
                    when "00000" => -- BLTZ
                        alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1';
                        is_branch_type <= '1'; br_type <= "0101";
                        imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
                    when "00001" => -- BGEZ
                        alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1';
                        is_branch_type <= '1'; br_type <= "0010";
                        imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );
                    when others => null;
                end case;

            when "000111" => -- BGTZ
                alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1';
                is_branch_type <= '1'; br_type <= "0011";
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );

            when "000110" => -- BLEZ
                alu_type <= "0001"; A <= "00"; B <= "00"; use_rs <= '1';
                is_branch_type <= '1'; br_type <= "0100";
                imm <= ( (31 downto 16 => inst(15)) & inst(15 downto 0) );

            -- J-type jumps
            when "000010" => -- J
                is_branch_type <= '1'; br_type <= "0110";
                imm <= ( "000000" & inst(25 downto 0) );
            when "000011" => -- JAL
                alu_type <= "1111"; reg_wen <= '1'; rd_idx <= "11111";
                is_branch_type <= '1'; br_type <= "0111";
                imm <= ( "000000" & inst(25 downto 0) );

            when others => null;
        end case;
    end process;
end Behavioral;