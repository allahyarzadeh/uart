-------------------------------------------------------------------------------
-- UART
-- Implements a universal asynchronous receiver transmitter
-------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity uart is
    generic (
        baud                : positive;
        clock_frequency     : positive
    );
    port (  
        clock               :   in  std_logic;
        reset               :   in  std_logic;    
        data_stream_in      :   in  std_logic_vector(7 downto 0);
        data_stream_in_stb  :   in  std_logic;
        data_stream_in_ack  :   out std_logic;
        data_stream_out     :   out std_logic_vector(7 downto 0);
        data_stream_out_stb :   out std_logic;
        data_stream_out_ack :   in  std_logic;
        tx                  :   out std_logic;
        rx                  :   in  std_logic
    );
end uart;

architecture rtl of uart is
    ---------------------------------------------------------------------------
    -- baud generation
    ---------------------------------------------------------------------------
    constant c_tx_divider       : integer := clock_frequency / baud;
    constant c_rx_divider       : integer := clock_frequency / (baud * 16);
    constant c_tx_divider_width : integer 
        := integer(ceil(log2(real(c_tx_divider))));   
    constant c_rx_divider_width : integer 
        := integer(ceil(log2(real(c_rx_divider))));   
    signal baud_counter         : unsigned(c_tx_divider_width-1 downto 0) 
        := (others => '0');   
    signal baud_tick            : std_logic := '0';
    signal over_baud_count      : unsigned(c_rx_divider_width-1 downto 0) 
        := (others => '0');  
    signal over_baud_tick : std_logic := '0';
    ---------------------------------------------------------------------------
    -- transmitter signals
    ---------------------------------------------------------------------------
    type uart_tx_states is ( 
        idle,
        wait_for_tick,
        send_start_bit,
        transmit_data,
        send_stop_bit
    );             
    signal uart_tx_state        : uart_tx_states := idle;
    signal uart_tx_data_block   : std_logic_vector(7 downto 0) 
        := (others => '0');
    signal uart_tx_data         : std_logic := '1';
    signal uart_tx_count        : unsigned(2 downto 0) 
        := (others => '0');
    signal uart_rx_data_in_ack  : std_logic := '0';
    ---------------------------------------------------------------------------
    -- receiver signals
    ---------------------------------------------------------------------------
    type uart_rx_states is ( 
        rx_wait_start_synchronise, 
        rx_get_start_bit, 
        rx_get_data, 
        rx_get_stop_bit, 
        rx_send_block
    );            
    signal uart_rx_state        : uart_rx_states := rx_get_start_bit;
    signal uart_rx_bit          : std_logic := '1';
    signal uart_rx_data_block   : std_logic_vector(7 downto 0) 
        := (others => '0');
    signal uart_rx_data_vec     : std_logic_vector(1 downto 0) 
        := (others => '1');
    signal uart_rx_filter       : unsigned(1 downto 0) := (others => '1');
    signal uart_rx_count        : unsigned(2 downto 0) := (others => '0');
    signal uart_rx_data_out_stb : std_logic := '0';
    signal uart_rx_bit_spacing  : unsigned (3 downto 0) := (others => '0');
    signal uart_rx_bit_tick     : std_logic := '0';
begin
    data_stream_in_ack <= uart_rx_data_in_ack;
    data_stream_out <= uart_rx_data_block;
    data_stream_out_stb <= uart_rx_data_out_stb;
    tx <= uart_tx_data;
    ---------------------------------------------------------------------------
    -- TX_CLOCK_DIVIDER
    -- Generate baud ticks at the required rate based on the input clock
    -- frequency and baud rate
    ---------------------------------------------------------------------------
    tx_clock_divider   : process (clock)
    begin
        if rising_edge (clock) then
            if reset = '1' then
                baud_counter <= (others => '0');
                baud_tick <= '0';    
            else
                if baud_counter = c_tx_divider then
                    baud_counter <= (others => '0');
                    baud_tick <= '1';
                else
                    baud_counter <= baud_counter + 1;
                    baud_tick <= '0';
                end if;
            end if;
        end if;
    end process tx_clock_divider;
    ---------------------------------------------------------------------------
    -- UART_SEND_DATA 
    -- Get data from data_stream_in and send it one bit at a time upon each 
    -- baud tick. Send data lsb first.
    -- wait 1 tick, send start bit (0), send data 0-7, send stop bit (1)
    ---------------------------------------------------------------------------
    uart_send_data :    process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                uart_tx_data <= '1';
                uart_tx_data_block <= (others => '0');
                uart_tx_count <= (others => '0');
                uart_tx_state <= idle;
                uart_rx_data_in_ack <= '0';
            else
                uart_rx_data_in_ack <= '0';
                case uart_tx_state is
                    when idle =>
                        if data_stream_in_stb = '1' then
                            uart_tx_data_block <= data_stream_in;
                            uart_rx_data_in_ack <= '1';
                            uart_tx_state <= wait_for_tick;
                        end if;                                   
                    when wait_for_tick =>
                        if baud_tick = '1' then
                            uart_tx_state <= send_start_bit;
                        end if;
                    when send_start_bit =>
                        if baud_tick = '1' then
                            uart_tx_data  <= '0';
                            uart_tx_state <= transmit_data;
                            uart_tx_count <= (others => '0');
                        end if;
                    when transmit_data =>
                        if baud_tick = '1' then
                            if uart_tx_count < 7 then
                                uart_tx_data <=
                                    uart_tx_data_block(
                                        to_integer(uart_tx_count)
                                    );
                                uart_tx_count <= uart_tx_count + 1;
                            else
                                uart_tx_data <= uart_tx_data_block(7);
                                uart_tx_count <= (others => '0');
                                uart_tx_state <= send_stop_bit;
                            end if;
                        end if;
                    when send_stop_bit =>
                        if baud_tick = '1' then
                            uart_tx_data <= '1';
                            uart_tx_state <= idle;
                        end if;
                    when others =>
                        uart_tx_data <= '1';
                        uart_tx_state <= idle;
                end case;
            end if;
        end if;
    end process uart_send_data;    
    ---------------------------------------------------------------------------
    -- OVERSAMPLE_CLOCK_DIVIDER
    -- generate an oversampled tick (baud * 16)
    ---------------------------------------------------------------------------
    oversample_clock_divider   : process (clock)
    begin
        if rising_edge (clock) then
            if reset = '1' then
                over_baud_count <= (others => '0');
                over_baud_tick <= '0';    
            else
                if over_baud_count = c_rx_divider then
                    over_baud_count <= (others => '0');
                    over_baud_tick <= '1';
                else
                    over_baud_count <= over_baud_count + 1;
                    over_baud_tick <= '0';
                end if;
            end if;
        end if;
    end process oversample_clock_divider;
    ---------------------------------------------------------------------------
    -- RXD_SYNCHRONISE
    -- Synchronise rxd to the oversampled baud
    ---------------------------------------------------------------------------
    rxd_synchronise : process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                uart_rx_data_vec <= (others => '1');
            else
                if over_baud_tick = '1' then
                    uart_rx_data_vec(0) <= rx;
                    uart_rx_data_vec(1) <= uart_rx_data_vec(0);
                end if;
            end if;
        end if;
    end process rxd_synchronise;
    ---------------------------------------------------------------------------
    -- RXD_FILTER
    -- filter rxd with a 2 bit counter.
    ---------------------------------------------------------------------------
    rxd_filter : process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                uart_rx_filter <= (others => '1');
                uart_rx_bit <= '1';
            else
                if over_baud_tick = '1' then
                    -- filter rxd.
                    if uart_rx_data_vec(1) = '1' and uart_rx_filter < 3 then
                        uart_rx_filter <= uart_rx_filter + 1;
                    elsif uart_rx_data_vec(1) = '0' and uart_rx_filter > 0 then
                        uart_rx_filter <= uart_rx_filter - 1;
                    end if;
                    -- set the rx bit.
                    if uart_rx_filter = 3 then
                        uart_rx_bit <= '1';
                    elsif uart_rx_filter = 0 then
                        uart_rx_bit <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process rxd_filter;
    ---------------------------------------------------------------------------
    -- RX_BIT_SPACING
    ---------------------------------------------------------------------------
    rx_bit_spacing : process (clock)
    begin
        if rising_edge(clock) then
            uart_rx_bit_tick <= '0';
            if over_baud_tick = '1' then       
                if uart_rx_bit_spacing = 15 then
                    uart_rx_bit_tick <= '1';
                    uart_rx_bit_spacing <= (others => '0');
                else
                    uart_rx_bit_spacing <= uart_rx_bit_spacing + 1;
                end if;
                if uart_rx_state = rx_get_start_bit then
                    uart_rx_bit_spacing <= (others => '0');
                end if; 
            end if;
        end if;
    end process rx_bit_spacing;
    ---------------------------------------------------------------------------
    -- UART_RECEIVE_DATA
    ---------------------------------------------------------------------------
    uart_receive_data   : process(clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                uart_rx_state <= rx_get_start_bit;
                uart_rx_data_block <= (others => '0');
                uart_rx_count <= (others => '0');
                uart_rx_data_out_stb <= '0';
            else
                case uart_rx_state is
                    when rx_get_start_bit =>
                        if over_baud_tick = '1' and uart_rx_bit = '0' then
                            uart_rx_state <= rx_get_data;
                        end if;
                    when rx_get_data =>
                        if uart_rx_bit_tick = '1' then
                            if uart_rx_count < 7 then
                                uart_rx_data_block(to_integer(uart_rx_count))
                                    <= uart_rx_bit;
                                uart_rx_count   <= uart_rx_count + 1;
                            else
                                uart_rx_data_block(7) <= uart_rx_bit;
                                uart_rx_count <= (others => '0');
                                uart_rx_state <= rx_get_stop_bit;
                            end if;
                        end if;
                    when rx_get_stop_bit =>
                        if uart_rx_bit_tick = '1' then
                            if uart_rx_bit = '1' then
                                uart_rx_state <= rx_send_block;
                                uart_rx_data_out_stb    <= '1';
                            end if;
                        end if;
                    when rx_send_block =>
                        if data_stream_out_ack = '1' then
                            uart_rx_data_out_stb <= '0';
                            uart_rx_data_block <= (others => '0');
                            uart_rx_state <= rx_get_start_bit;
                        else
                            uart_rx_data_out_stb <= '1';
                        end if;                                
                    when others =>
                        uart_rx_state <= rx_get_start_bit;
                end case;
            end if;
        end if;
    end process uart_receive_data;
end rtl;