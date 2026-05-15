;***************************************************************************
;*
;* Title: send_inventory
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48 @ 4MHz
;*
;* DESCRIPTION
;* Lab 12 - Inventory System with LoRaWAN
;* 1. Scans barcode.
;* 2. Accepts item count from keypad.
;* 3. Waits for ENTER key.
;* 4. Sends "Count = <val>, ID = <barcode>" to Base Station (Addr 100).
;*
;*
;* VERSION HISTORY
;* 1.0 Original version
;***************************************************************************

.nolist
.include "avr128db48def.inc"
.list
.equ PAGE_SIZE = 80
.equ LORA_BAUD = 139 ; 115200 baud calculation for 4MHz (approx)

.dseg
page_1_buff:    .byte PAGE_SIZE     ; 80-byte page buffer
page_2_buff:    .byte PAGE_SIZE     ; 80-byte page buffer
number:         .byte 2             ; Stores the 2-digit count (ASCII)
scanned_data:   .byte 40            ; Stores the scanned barcode
unsigned_val:   .byte 1
; New buffers for Lab 12
tx_buff:        .byte 100           ; Buffer for full AT command string
payload_buff:   .byte 60            ; Temporary buffer for payload calculation
tx_ptr:         .byte 2             ; Pointer to current char to send
last_key_pressed: .byte 1           ; Shared variable to detect ENTER press

.cseg

; -----------------------------------------------------------------------------
; INTERRUPT VECTORS
; -----------------------------------------------------------------------------
.org 0x00
    jmp init

.org PORTE_PORT_vect     ; Vector 8 (Port E - Keypad)
    jmp porte_isr

.org USART1_RXC_vect     ; Vector 25 (USART1 - Scanner)
    jmp USART1_RXC_ISR

.org USART2_DRE_vect     ; Vector 29 (USART2 - LoRaWAN) - NEW
    jmp USART2_DRE_ISR

.org USART3_DRE_vect     ; Vector 32 (USART3 - LCD)
    jmp USART3_DRE_ISR

; -----------------------------------------------------------------------------
; MAIN INIT
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "init" - Initialization Routine
;*
;* Description: Initializes ports, buffers, and USARTs
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r17, r20
;* High registers modified:
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
init:
    ; Initialize LCD TX Pin (PB0)
    sbi VPORTB_DIR, 0 
    sbi VPORTB_OUT, 0

    ; Initialize LoRa TX Pin (PF0) - NEW
    sbi VPORTF_DIR, 0
    sbi VPORTF_OUT, 0

    rcall build_page_1
    ldi r17, 0          ; 0 => first page

    rcall USART3_init   ; LCD
    rcall USART1_init   ; Scanner
    rcall USART2_init   ; LoRaWAN (NEW)

    rcall clear_page
    rcall start_tx      ; transmit cover page
    ldi r20, 200        ; delay loop
    rcall delay_loop

end:
    rcall clear_page
    rcall build_page_2  ; build page 2 layout
    ldi r17, 1          ; 1 => page 2 line 1
    rcall start_tx      
    
    rcall clear_number
    rcall get_number    ; get count from user
    rcall convert_str_to_unsign
    
    ldi r17, 2          ; 2 => page 2 line 3
    rcall start_tx      

    ; 1. Scan Barcode
    rcall scan_to_LCD   

    ; 2. Wait for Operator to press ENTER (0x0C)
    rcall wait_for_enter

    ; 3. Construct and Send LoRaWAN Packet
    rcall construct_packet
    rcall start_lora_tx

    rjmp end

; -----------------------------------------------------------------------------
; USART2 (LoRaWAN) Initialization
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "USART2_init" - USART2 Initialization
;*
;* Description: Configures USART2 for LoRaWAN communication (115200 8N1)
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified:
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
USART2_init:
    ; Set Baud Rate 115200 (139 @ 4MHz)
    ldi r16, LOW(LORA_BAUD)
    sts USART2_BAUDL, r16
    ldi r16, HIGH(LORA_BAUD)
    sts USART2_BAUDH, r16

    ; 8N1 Format
    ldi r16, 0b00000011 
    sts USART2_CTRLC, r16

    ; Enable Transmitter Only
    ldi r16, 0b01000000 
    sts USART2_CTRLB, r16
    
    ; Debug Control (Run in debug)
    ldi r16, 0b00000001
    sts USART2_DBGCTRL, r16
    ret

; -----------------------------------------------------------------------------
; Construct LoRa Packet
; Format: AT+SEND=100,<Len>,Count = <XX>, ID = <Barcode>\r\n
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "construct_packet" - Packet Construction
;*
;* Description: Builds the AT command string in the tx_buff
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r17, r18
;* High registers modified: X, Y, Z
;*
;* Parameters: None (Uses global buffers)
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
construct_packet:
    ; Step A: Build Payload into payload_buff first to calculate length
    ; Payload Format: "Count = XX, ID = XXXXX"
    
    ldi XL, low(payload_buff)
    ldi XH, high(payload_buff)
    
    ; Copy "Count = "
    ldi ZL, low(str_count << 1)
    ldi ZH, high(str_count << 1)
    rcall copy_flash_str
    
    ; Copy Count Digits (from 'number' var)
    ldi YL, low(number)
    ldi YH, high(number)
    ld r16, Y+
    st X+, r16
    ld r16, Y
    st X+, r16
    
    ; Copy ", ID = "
    ldi ZL, low(str_id << 1)
    ldi ZH, high(str_id << 1)
    rcall copy_flash_str
    
    ; Copy Barcode (from 'scanned_data', stop at CR 0x0D)
    ldi YL, low(scanned_data)
    ldi YH, high(scanned_data)
copy_barcode_lp:
    ld r16, Y+
    cpi r16, 0x0D       ; Check for CR
    breq calc_len
    st X+, r16
    rjmp copy_barcode_lp
    
calc_len:
    ; Calculate Payload Length = (Current X) - (Start of payload_buff)
    ldi r16, low(payload_buff)
    mov r17, XL
    sub r17, r16        ; r17 now holds length of payload (e.g., 25)
    
    ; Step B: Build Full Command into tx_buff
    ; Format: "AT+SEND=100,<Len>," + Payload + "\r\n"
    
    ldi XL, low(tx_buff)
    ldi XH, high(tx_buff)
    
    ; Copy "AT+SEND=100,"
    ldi ZL, low(str_at_cmd << 1)
    ldi ZH, high(str_at_cmd << 1)
    rcall copy_flash_str
    
    ; Convert Length (r17) to ASCII string and store
    rcall int_to_ascii
    
    ; Add comma separator
    ldi r16, ','
    st X+, r16
    
    ; Copy content of payload_buff to tx_buff
    ldi YL, low(payload_buff)
    ldi YH, high(payload_buff)
    mov r18, r17        ; Use calculated length as counter
copy_pld_final:
    ld r16, Y+
    st X+, r16
    dec r18
    brne copy_pld_final
    
    ; Add CR LF
    ldi r16, '\r'
    st X+, r16
    ldi r16, '\n'
    st X+, r16
    
    ; Add NULL terminator for ISR
    ldi r16, 0
    st X+, r16
    ret

; Helper: Copy Flash String (Z) to RAM (X)
;***************************************************************************
;* ;* "copy_flash_str" - String Copy
;*
;* Description: Copies a null-terminated string from Flash (Z) to RAM (X)
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: X, Z
;*
;* Parameters: Z (Source), X (Dest)
;*
;* Returns: Updated X pointer
;*
;* Notes: 
;*
;***************************************************************************
copy_flash_str:
    lpm r16, Z+
    tst r16
    breq copy_ret
    st X+, r16
    rjmp copy_flash_str
copy_ret:
    ret

; Helper: Convert byte in r17 to ASCII decimal at X
;***************************************************************************
;* ;* "int_to_ascii" - Integer to ASCII
;*
;* Description: Converts a byte value (r17) to 2 ASCII digits at X
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r19
;* High registers modified: X
;*
;* Parameters: r17 (Value), X (Dest)
;*
;* Returns: Updated X pointer
;*
;* Notes: 
;*
;***************************************************************************
int_to_ascii:
    push r17            ; Preserve the original length; caller still needs it
    ldi r19, 0          ; Tens count
count_tens:
    cpi r17, 10
    brlo write_digits
    subi r17, 10
    inc r19
    rjmp count_tens
write_digits:
    ldi r16, '0'
    add r16, r19
    st X+, r16
    ldi r16, '0'
    add r16, r17
    st X+, r16
    pop r17             ; Restore original length for the caller
    ret

; -----------------------------------------------------------------------------
; Start LoRa Transmission
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "start_lora_tx" - Start Transmission
;*
;* Description: Enables the DRE interrupt to begin sending the buffer
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
start_lora_tx:
    ; Set pointer to beginning of buffer
    ldi r16, low(tx_buff)
    sts tx_ptr, r16
    ldi r16, high(tx_buff)
    sts tx_ptr+1, r16
    
    ; Enable USART2 DRE Interrupt (Starts transmission)
    lds r16, USART2_CTRLA
    ori r16, 0b00100000 
    sts USART2_CTRLA, r16
    ret

; -----------------------------------------------------------------------------
; USART2 DRE ISR (Interrupt Driver)
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "USART2_DRE_ISR" - USART2 Data Register Empty ISR
;*
;* Description: Handles interrupt-driven transmission for LoRaWAN
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: Saves and restores context
;*
;***************************************************************************
USART2_DRE_ISR:
    push r16
    push XL
    push XH
    in r16, CPU_SREG
    push r16
    
    ; Load current pointer
    lds XL, tx_ptr
    lds XH, tx_ptr+1
    
    ld r16, X+          ; Get byte
    tst r16             ; Check for NULL terminator
    breq stop_tx
    
    sts USART2_TXDATAL, r16 ; Send byte
    
    ; Save incremented pointer
    sts tx_ptr, XL
    sts tx_ptr+1, XH
    rjmp exit_u2_isr
    
stop_tx:
    ; Disable DRE Interrupt
    lds r16, USART2_CTRLA
    andi r16, 0b11011111 
    sts USART2_CTRLA, r16

exit_u2_isr:
    pop r16
    out CPU_SREG, r16
    pop XH
    pop XL
    pop r16
    reti

; -----------------------------------------------------------------------------
; Wait for Enter Key
; -----------------------------------------------------------------------------
;***************************************************************************
;* ;* "wait_for_enter" - Wait Loop
;*
;* Description: Polling loop waiting for the Keypad ISR to flag an ENTER press
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: Blocks until ENTER is pressed
;*
;***************************************************************************
wait_for_enter:
    ; Reset the last key variable
    ldi r16, 0
    sts last_key_pressed, r16
wait_enter_loop:
    lds r16, last_key_pressed
    cpi r16, 0x0C       ; Check for ENTER code
    brne wait_enter_loop
    ret

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
; Strings MUST be null-terminated for copy_flash_str (which scans for 0x00).
; The trailing 0 also pads odd-length strings to a whole word for flash storage.
str_at_cmd: .db "AT+SEND=100,", 0
str_count:  .db "Count = ", 0
str_id:     .db ", ID = ", 0, 0

;***************************************************************************
;* ;* "build_page_1" - Page Builder
;*
;* Description: Populates the page 1 buffer
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
build_page_1:
    ldi XL, low(page_1_buff)
    ldi XH, high(page_1_buff)
    ldi r18, 20
line1:
    ldi r16, ' '
    st X+, r16
    dec r18
    brne line1
    rcall line2
    rcall line3
    rcall line4
    ret
;***************************************************************************
;* ;* "line2" - Line Builder
;*
;* Description: Populates line 2 of page 1
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Z, X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
line2:
    ldi ZL, low(line2str << 1)
    ldi ZH, high(line2str << 1)
    ldi r18, 20
loop_line2:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne loop_line2
    ret
line2str: .db " Inventory System I "
;***************************************************************************
;* ;* "line3" - Line Builder
;*
;* Description: Populates line 3 of page 1
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Z, X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
line3:
    ldi ZL, low(line3str << 1)
    ldi ZH, high(line3str << 1)
    ldi r18, 20
loop_line3:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne loop_line3
    ret
line3str: .db "  ESE280 Fall 2025  "
;***************************************************************************
;* ;* "line4" - Line Builder
;*
;* Description: Populates line 4 of page 1
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Z, X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
line4:
    ldi ZL, low(line4str << 1)
    ldi ZH, high(line4str << 1)
    ldi r18, 20
loop_line4:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne loop_line4
    ret
line4str: .db "     <Andy Xie>     "

;***************************************************************************
;* ;* "build_page_2" - Page Builder
;*
;* Description: Populates the page 2 buffer
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
build_page_2:
    ldi XL, low(page_2_buff)
    ldi XH, high(page_2_buff)
    rcall p2line1
    ldi r18, 20
p2line2:
    ldi r16, ' '
    st X+, r16
    dec r18
    brne p2line2
    rcall p2line3
    ldi r18, 20
p2line4:
    ldi r16, ' '
    st X+, r16
    dec r18
    brne p2line4
    ret

;***************************************************************************
;* ;* "p2line1" - Line Builder
;*
;* Description: Populates line 1 of page 2
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Z, X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
p2line1:
    ldi ZL, low(p2line1str << 1)
    ldi ZH, high(p2line1str << 1)
    ldi r18, 20
loop_p2line1:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne loop_p2line1
    ret
p2line1str: .db "Enter item count:   "

;***************************************************************************
;* ;* "p2line3" - Line Builder
;*
;* Description: Populates line 3 of page 2
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Z, X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
p2line3:
    ldi ZL, low(p2line3str << 1)
    ldi ZH, high(p2line3str << 1)
    ldi r18, 20
loop_p2line3:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne loop_p2line3
    ret
p2line3str: .db "Scan barcode:       "

;***************************************************************************
;* ;* "USART3_init" - USART3 Initialization
;*
;* Description: Configures USART3 for LCD communication
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
USART3_init:
    ldi r16, LOW(1667)
    sts USART3_BAUDL, r16
    ldi r16, HIGH(1667)
    sts USART3_BAUDH, r16
    ldi r16, 0b00000011
    sts USART3_CTRLC, r16
    ldi r16, 0b01000000
    sts USART3_CTRLB, r16
    ldi r16, 0b00000001
    sts USART3_DBGCTRL, r16
    ret

;***************************************************************************
;* ;* "USART1_init" - USART1 Initialization
;*
;* Description: Configures USART1 for Barcode Scanner communication
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
USART1_init:
    cbi VPORTC_DIR, 1
    ldi r16, LOW(139)
    sts USART1_BAUDL, r16
    ldi r16, HIGH(139)
    sts USART1_BAUDH, r16
    ldi r16, 0b00000011
    sts USART1_CTRLC, r16
    ldi r16, 0b10000000
    sts USART1_CTRLB, r16
    ldi r16, 0b00000000
    sts USART1_CTRLA, r16
    ldi r16, 0b00000001
    sts USART1_DBGCTRL, r16
    ret

;***************************************************************************
;* ;* "start_tx" - Transmission Trigger
;*
;* Description: Starts transmission of selected page/line to LCD
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: X
;*
;* Parameters: r17 (Selection)
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
start_tx:
    cpi r17, 0
    breq page_1
    cpi r17, 1
    breq page_2_line1
    cpi r17, 2
    breq page_2_line3
    ret                 ; Unknown selector: do nothing instead of falling through
page_1:
    ldi XL, low(page_1_buff)
    ldi XH, high(page_1_buff)
    ldi r18, 1
    rjmp enable_DREIF
page_2_line1:
    ldi XL, low(page_2_buff)
    ldi XH, high(page_2_buff)
    ldi r18, 1
    rjmp enable_DREIF
page_2_line3:
    ldi XL, low(page_2_buff+40)
    ldi XH, high(page_2_buff+40)
    ldi r18, 2
    rjmp enable_DREIF

enable_DREIF:
    ldi r16, 0b00100000
    sts USART3_CTRLA, r16
    sei
wait_disable_DREIF:
    lds r21, USART3_CTRLA
    sbrc r21, 5
    rjmp wait_disable_DREIF
    ret

;***************************************************************************
;* ;* "USART3_DRE_isr" - USART3 ISR
;*
;* Description: Handles data transmission to LCD
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: X
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
USART3_DRE_isr:
    cli
    cpi r17, 0
    breq page_1_tx
    cpi r17, 1
    breq page_2_l1_tx
    cpi r17, 2
    breq page_2_l3_tx
page_1_tx:
    ld r16, X+
    sts USART3_TXDATAL, r16
    cpi r18, PAGE_SIZE
    brge done_tx
    inc r18
    sei
    reti
page_2_l1_tx:
    ld r16, X+
    sts USART3_TXDATAL, r16
    cpi r18, 20
    brge done_tx
    inc r18
    sei
    reti
page_2_l3_tx:
    ld r16, X+
    sts USART3_TXDATAL, r16
    cpi r18, 20
    brge done_tx
    inc r18
    sei
    reti
done_tx:
    ldi r16, 0b00000000
    sts USART3_CTRLA, r16
    sei 
    reti

;***************************************************************************
;* ;* "get_number" - Keypad Input
;*
;* Description: Configures Keypad to accept input for Item Count
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r22
;* High registers modified: X, Y
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
get_number:
    ldi r22, 0 
    cbi VPORTE_DIR, 3 
    sei 
    ldi r16, 0x00
    out VPORTC_DIR, r16 
    lds r16, PORTE_PIN3CTRL 
    ori r16, 0x02 
    sts PORTE_PIN3CTRL, r16
    ldi XL, low(page_2_buff+20)
    ldi XH, high(page_2_buff+20)
    ldi YL, low(number)
    ldi YH, high(number)

    ; Clear the shared key flag before polling
    ldi r16, 0
    sts last_key_pressed, r16

wait_enter_press:
    lds r16, last_key_pressed
    cpi r16, 0x0c
    brne wait_enter_press

    ldi r16, 0x0D 
    rcall send_USART3
    ldi r16, 0x0A
    rcall send_USART3
    ret

;***************************************************************************
;* ;* "clear_number" - Clear Buffer
;*
;* Description: Clears the number buffer
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18
;* High registers modified: Y
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
clear_number:
    ldi r18, 2
    ldi YL, low(number)
    ldi YH, high(number)
    ldi r16, 0
clear_loop:
    st Y+, r16
    dec r18
    brne clear_loop
    ret

;***************************************************************************
;* ;* "convert_str_to_unsign" - String Conversion
;*
;* Description: Converts ASCII string to unsigned integer
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r18, r22, r23
;* High registers modified: Y
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
convert_str_to_unsign:
    ldi r16, 0 
    ldi YL, low(number)
    ldi YH, high(number)
convert_loop:
    mov r23, r16
    ldi r18, 9
multiply_loop:
    add r16, r23
    dec r18
    brne multiply_loop
    ld r23, Y+
    add r16, r23
    dec r22
    brne convert_loop
    ldi YL, low(unsigned_val)
    ldi YH, high(unsigned_val)
    st Y, r16
    ret

;***************************************************************************
;* ;* "porte_isr" - Keypad ISR
;*
;* Description: Handles key presses from the matrix keypad
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r22
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
porte_isr:
    ; Save context. ISRs must not clobber caller's registers / SREG.
    push r16
    in r16, CPU_SREG
    push r16
    push r21
    push ZL
    push ZH

    in r16, VPORTC_IN 
    lsr r16
    lsr r16
    lsr r16
    lsr r16
    andi r16, 0x0F 
    rcall scan_to_value 

    ; Save the decoded key for the main loop to poll
    sts last_key_pressed, r16
    
    ori r16, 0x30
    rcall send_USART3
    andi r16, 0x0f
    cpi r16, 0x0c
    breq done_enter
    st Y+, r16
    inc r22
    ori r16, 0x30
    st X+, r16
done_enter:
    ldi r16, PORT_INT3_bm 
    sts PORTE_INTFLAGS, r16

    pop ZH
    pop ZL
    pop r21
    pop r16
    out CPU_SREG, r16
    pop r16
    reti

;***************************************************************************
;* ;* "scan_to_value" - Keypad Lookup
;*
;* Description: Converts raw key code to ASCII value using lookup table
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r21
;* High registers modified: Z
;*
;* Parameters: r16 (Key Code)
;*
;* Returns: r16 (ASCII Value)
;*
;* Notes: 
;*
;***************************************************************************
scan_to_value:
    ldi ZH, high(table * 2) 
    ldi ZL, low(table * 2)
    ldi r21, 0x00 
    add ZL, r16
    adc ZH, r21
    lpm r16, Z 
    ret
table: .db 0x01, 0x02, 0x03, 0x0f, 0x04, 0x05, 0x06, 0x0e, 0x07, 0x08, 0x09, 0x0d, 0x0a, 0x00, 0x0b, 0x0c

;***************************************************************************
;* ;* "send_USART3" - Send Byte
;*
;* Description: Sends a single byte via USART3 (LCD)
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: R21
;* High registers modified: None
;*
;* Parameters: R16 (Byte to send)
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
send_USART3:
wait_data_empty:
    lds R21, USART3_STATUS
    sbrs R21, 5 
    rjmp wait_data_empty
    sts USART3_TXDATAL, R16
    ret

;***************************************************************************
;* ;* "clear_page" - Clear LCD
;*
;* Description: Sends command to clear the LCD screen
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
clear_page:
    ldi r16, 0x7C 
    rcall send_USART3
    ldi r16, 0x2D 
    rcall send_USART3
    ret

;***************************************************************************
;* ;* "receive_USART1" - Receive Byte
;*
;* Description: Receives a single byte from USART1 (Scanner)
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r21
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: r16 (Received Byte)
;*
;* Notes: 
;*
;***************************************************************************
receive_USART1:
wait_receive:
    lds r21, USART1_STATUS
    sbrs r21, 7 
    rjmp wait_receive
    lds r16, USART1_RXDATAL 
    ret

;***************************************************************************
;* ;* "scan_to_LCD" - Display Scan
;*
;* Description: Reads scanned barcode and displays it on LCD
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16
;* High registers modified: Y
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
scan_to_LCD:
    ldi YL, LOW(scanned_data)
    ldi YH, HIGH(scanned_data) 
store_until_CR:
    rcall receive_USART1 
    st Y+, r16 
    cpi r16, 0x0D
    brne store_until_CR 

    ldi YL, LOW(scanned_data)
    ldi YH, HIGH(scanned_data) 
send_until_CR:
    ld r16, Y+ 
    rcall send_USART3 
    cpi r16, 0x0D
    brne send_until_CR 
    ret

;***************************************************************************
;* ;* "USART1_RXC_ISR" - USART1 ISR
;*
;* Description: Interrupt handler for USART1 Receive
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: None
;* High registers modified: None
;*
;* Parameters: None
;*
;* Returns: None
;*
;* Notes: Placeholder for future use
;*
;***************************************************************************
USART1_RXC_ISR:
    reti

;***************************************************************************
;* ;* "delay_loop" - Long Delay
;*
;* Description: Loops the variable delay for a longer duration
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r19, r20
;* High registers modified: None
;*
;* Parameters: r20 (Multiplier)
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
delay_loop:
    ldi r19, 100 
    rcall var_delay
    dec r20
    brne delay_loop
    ret

;***************************************************************************
;* ;* "var_delay" - Short Delay
;*
;* Description: Provides a short variable delay
;*
;* Author: Andy Xie
;* Version: 1.0
;* Last updated: Nov 30, 2025
;* Target: AVR128DB48
;* Number of words:
;* Number of cycles:
;* Low registers modified: r16, r19
;* High registers modified: None
;*
;* Parameters: r19 (Delay count)
;*
;* Returns: None
;*
;* Notes: 
;*
;***************************************************************************
var_delay: 
outer_loop:
    ldi r16, 133
inner_loop:
    dec r16
    brne inner_loop
    dec r19
    brne outer_loop
    ret