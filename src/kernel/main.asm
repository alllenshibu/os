org		0x0		
bits	16				; 16 bit mode. 8086only has 16 bit registers

; 0x0D = carriage return
; 0x0A = line feed
%define ENDL 0x0D, 0x0A

start:

	; print message
	mov 	si, msg_hello
	call	puts

.halt:
	cli
	hlt
;
; Prints a string to the screen
; Params: 
;	- ds:si = pointer to string
;
;
;	AH = 0x0E
;   AL = character to print
;   BH = page number
;   BL = foreground color (graphics modes only)
;
puts:
    pusha           	; Save registers. Good practice
    mov     ah, 0x0E    ; BIOS teletype function (int 10h)
    mov     bh, 0       ; Page number (0 for most video modes)

.loop:
    lodsb               ; Load the next character into AL
    or      al, al      ; Check if it's the null terminator
    jz      .done       ; If it is, we're done. js is jump if zero
    int     0x10        ; Otherwise, print the character 10h is the interrupt for video
    jmp     .loop       ; Repeat for the next character

.done:
    popa            	; Restore registers
    ret

msg_hello: db 'Hello World from KERNEL', ENDL, 0

