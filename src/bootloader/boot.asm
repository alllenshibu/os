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
	; setup data segments
	mov 	ax, 0 						; can't write to ds/es directly
	mov 	ds, ax
	mov 	es, ax

	; setup stack
	mov 	ss, ax
	mov 	sp, 0x7C00					; stack grows down from where we are loaded in memory

	; some BIOSes might start us at 07X0:0000 instead of 0000:7C00, make sure we are in the 
	; expected location
	push 	es
	push 	word .after
	retf

.after:
	; read something from floppy
	; BIOS should set dl to drive number
	mov 	[ebr_drive_number], dl

	; show loading message
	mov 	si, msg_loading
	call	puts

	; read drive parameters (sectors per track and head count)'
	; instead of relying on data on formatted disk
	push	 es
	mov 	ah, 08h
	int 	13h
	jc 		floppy_error
	pop 	es

	and 	cl, 0x3F 					; remove top 2 bits
	xor 	ch, ch
	mov 	[bdb_sectors_per_track], cx ; sector count

	inc 	dh
	mov 	[bdb_heads], dh 			; head count

	; computer LBA of root directory = reserved + fats * sectors_per_fat
	; note: this section can be hardcoded
	mov 	ax, [bdb_sectors_per_fat] ; LBA of root directory = reserved + fats  sectors_per_fat
	mov		 bl, [bdb_number_of_fats]
	xor		 bh, bh
	mul 	bx 							; ax = fats * sectors_per_fat
	add 	bx , [bdb_reserved_sectors] ; ax = LBA of root directory
	push 	ax

	; compute size of root directory = (32 * number_of_entries) / bytes_per_sector
	mov 	ax, [bdb_dir_entries_count]
	shl 	ax, 5						; ax *= 32
	xor 	dx, dx						; dx = 0
	div 	word  [bdb_bytes_per_sector] ; number of sectors we need to read

	test 	dx, dx						; if dx != 0, add 1
	jz 		.root_dir_after
	inc 	ax							; division reminder != 0, add 1
										; this means we have a sector partially filled with entries

.root_dir_after:
	; read root directory
	mov 	cl, al						; cl = number of sectors to read = size of root directory
	pop 	ax							; ax = LBA of root directory
	mov 	dl, [ebr_drive_number]		; dl = drive number
	mov 	bx, buffer					; es:bs = buffer
	call 	disk_read

	; search for kernel.bin
	xor 	bx, bx
	mov 	di, buffer

.search_kernel:
	mov 	si, file_kernel_bin
	mov 	cx, 11
	push 	di
	repe 	cmpsb						; repe - repeat while equal; until cx = 0, cx decremented every iteration
	pop 	di
	je 		.found_kernel

	add 	di, 32						; 32 bytes per entry
	inc 	bx
	cmp 	bx, [bdb_dir_entries_count]
	jl 		.search_kernel

	; kernel not found
	jmp 	kernel_not_found

.found_kernel:
	; di should have the address of the kernel entry
	mov 	ax, [di + 26]				; first logical cluster field (offset 26)
	mov 	[kernel_cluster], ax 

	; load FAT from disk to memory
	mov 	ax,  [bdb_reserved_sectors]
	mov 	bx, buffer
	mov 	cl, [bdb_sectors_per_fat]
	mov 	dl, [ebr_drive_number]
	call 	disk_read

	; read kernel and pricess FAT chain
	mov 	bx, KERNEL_LOAD_SEGMENT
	mov 	es, bx
	mov 	bx, KERNEL_LOAD_OFFSET

.load_kernel_loop:
	; read next cluster
	mov	 	ax, [kernel_cluster]

	; HARDCODED AANU CHANGE THIS
	add 	ax, 31							; first cluster = (kernel_cluster - 1) * sectors_per_cluster + start_cluster
											; start sector = reserved + fats * root directory size = 1 * 18 * 134 = 33
	mov 	cl, 1
	mov 	dl, [ebr_drive_number]
	call 	disk_read

	add 	bx, [bdb_bytes_per_sector]

	; compute location of next cluster
	mov 	ax, [kernel_cluster]
	mov 	cx, 3
	mul 	cx
	mov 	cx, 2
	div 	cx 								; ax = index of entry in FAT, dx = cluster mod 2

	mov 	si, buffer
	add 	si, ax
	mov 	ax, [ds:si]						; ax = read entry fron FAT table at index ax

	or 		dx, dx
	jz 		.even

.odd:
	shr 	ax, 4
	jmp 	.next_cluster_after
.even:
	and 	ax, 0xFFF

.next_cluster_after:
	cmp 	ax, 0xFF8						; end of chain
	jae 	.read_finish

	mov 	[kernel_cluster], ax
	jmp 	.load_kernel_loop

.read_finish:
	; jump to our kernel
	mov 	dl, [ebr_drive_number]			; boot device in dl

	mov 	ax, KERNEL_LOAD_SEGMENT			; set segment registers
	mov 	ds, ax
	mov 	es, ax

	jmp 	KERNEL_LOAD_SEGMENT:KERNEL_LOAD_OFFSET

	jmp 	wait_key_and_reboot 			; should never get here

	cli										; disable interrupts	
	hlt

;
; Error handlers
;
floppy_error:
	mov 	si, msg_read_failed
	call 	puts
	jmp 	wait_key_and_reboot

kernel_not_found:
	mov 	si, msg_kernel_not_found
	call 	puts
	jmp 	wait_key_and_reboot

wait_key_and_reboot:
	mov		ah, 0
	int 	16h								; wait for key press
	jmp 	0FFFFh:0						; jump to FFFF:0, which is the BIOS reset vector

.halt:
	cli										; disable interrupts
	hlt										; halt the CPU
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
    pusha           						; Save registers. Good practice
    mov     ah, 0x0E    					; BIOS teletype function (int 10h)
    mov     bh, 0       					; Page number (0 for most video modes)

.loop:
    lodsb               					; Load the next character into AL
    or      al, al      					; Check if it's the null terminator
    jz      .done       					; If it is, we're done. js is jump if zero
    int     0x10        					; Otherwise, print the character 10h is the interrupt for video
    jmp     .loop       					; Repeat for the next character

.done:
    popa            						; Restore registers
    ret

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


msg_loading: 			db 'Loading...', ENDL, 0
msg_read_failed:		db 'Read from disk failed', ENDL, 0
msg_kernel_not_found: 	db 'KERNEL.BIN file not found!', ENDL, 0
file_kernel_bin: 		db 'KERNEL  BIN'
kernel_cluster: 		dw 0

KERNEL_LOAD_SEGMENT: 	equ 0x2000
KERNEL_LOAD_OFFSET: 	equ 0x0000

times		510-($-$$) db 0
dw 			0AA55h

buffer: 
