org		0x7C00			; BIOS looks for stuff here
bits	16				; 16 bit mode. 8086only has 16 bit registers

; 0x0D = carriage return
; 0x0A = line feed
%define ENDL 0x0D, 0x0A


;
; FAT12 header
;
jmp						short start
nop

bdb_oem:					db 'MSWIN4.1' 		; OEM identifier 8 bytes
bdb_bytes_per_sector:		dw 512				; Bytes per sector
bdb_sectors_per_cluster:	db 1				; Sectors per cluster
bdb_reserved_sectors:		dw 1				; Reserved sectors
bdb_number_of_fats:			db 2				; Number of FATs
bdb_dir_entries_count:		dw 0E0h				
bdb_total_sectors:			dw 2880				; 2880 * 512 = 1.44MB
bdb_meta_descriptor_type: 	db 0F0h				; 3.5" floppy
bdb_sectors_per_fat:		dw 9				; Sectors per FAT
bdb_sectors_per_track:		dw 18				; Sectors per track
bdb_heads: 					dw 2				; Number of heads
bdb_hidden_sectors:			dd 0				; Number of hidden sectors
bdb_large_total_sectors:	dd 0				; Large total sectors

; extended boot records
ebr_drive_number:			db 0				; 0x00 floppy, 0x80 hdd, etc
							db 0				; reserved
ebr_signature: 				db 29h
ebr_volume_id:				db 12h, 34h, 56h, 78h				; volume serial number
ebr_volume_label: 			db 'ALLENTE OS '	; 11 bytes
ebr_system_id:				db 'FAT12   '		; 8 bytes

start:
	jmp 	main

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

main:

	; setup data segments
	mov 	ax, 0 					; can't write to ds/es directly
	mov 	ds, ax
	mov 	es, ax

	; setup stack
	mov 	ss, ax
	mov 	sp, 0x7C00				; stack grows down from where we are loaded in memory

	; read something from floppy
	; BIOS should set dl to drive number
	mov 	[ebr_drive_number], dl

	mov 	ax, 1					; LBA = 1, second sector from disk
	mov 	cl, 1					; read 1 sector	
	mov 	bx, 0x7E00				; data should buffer after bootloader
	call 	disk_read

	; print message
	mov 	si, msg_hello
	call	puts

	cli							; disable interrupts	
	hlt


;
; Error handlers
;
floppy_error:
	mov 	si, msg_read_failed
	call 	puts
	jmp 	wait_key_and_reboot

wait_key_and_reboot:
	mov		ah, 0
	int 	16h					; wait for key press
	jmp 	0FFFFh:0			; jump to FFFF:0, which is the BIOS reset vector


.halt:
	cli							; disable interrupts
	hlt							; halt the CPU


;
; Disk routines
;

;
; LBA to CHS
; Params:
;	- ax: LBA
; Returns:
;	- cx [bits 0-5]: sector
;	- cx [bits 6-15]: cylinder
;	- dh: head
;

lba_to_chs:

	push 	ax
	push 	dx

	xor 	dx, dx
	div		word [bdb_sectors_per_track]	; ax = LBA / sectors per track
											; dx = LBA % sectors per track
	
	inc 	dx								; dx = LBA % sectors per track + 1 = sector --> cx
	mov		cx, dx							; cx = sector

	xor 	dx, dx
	div		word [bdb_heads]				; ax = LBA / sectors per track / heads = cylinder --> cx
											; dx = LBA % sectors per track % heads = head --> dh

	mov 	dh, dl							; dh = head
	mov 	ch, al							; ch = cylinder
	shl 	ah, 6							
	or		cl, ah

	pop 	ax
	mov		dl, al
	pop		ax
	
	ret

;
; Reads sectors from a disk
; Params:
;	- ax: number of sectors to read
;	- ax: LBA
;	- dl: drive number
;	- es:bx: buffer to read into
;
disk_read:
	push	ax
	push 	bx
	push 	cx
	push 	dx
	push 	di

	push 	cx
	call 	lba_to_chs
	pop 	ax								; AL = number of sectors to read

	mov 	ah, 02h
	mov 	di, 3							; retry count

.retry:
	pusha
	stc										; set carry flag. just to be safe
	int		13h								; carry flag is cleared if successful
	jnc 	.done
	
	; fail
	popa
	call	 disk_reset

	dec 	di
	test	di, di
	jnz		.retry

.fail:
	jmp 	floppy_error

.done:
	popa

	pop		di
	pop 	dx
	pop 	cx
	pop 	bx
	pop 	ax
	ret

;
; Resets disk controller
; Params:
; 	- dl: drive number
;
disk_reset:
	pusha
	mov 	ah, 0
	stc
	int 	13h
	jc 		floppy_error
	popa
	ret


msg_hello: 			db 'Hello World!', ENDL, 0
msg_read_failed:	db 'Read from disk failed', ENDL, 0

times		510-($-$$) db 0
dw 			0AA55h
