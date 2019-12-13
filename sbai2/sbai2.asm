; written by Leonardo Ono (ono.leo@gmail.com)
; 13/12/2019
; assembler: NASM
; to assemble, use: build.bat

	bits 16
	
	global start
	
	AUDIO_BIT_DEPTH equ 8 ; note: in this implementation, only 8-bit audio depth is supported for now
	SB_BASE_ADDR equ 220h ; possible values: 220, 240, 260, 280, 2a0, 2c0, 2e0, 300
	SB_IRQ equ 7 ; in this implementation, supports 0~15. Note: setup_irq_dma function can configure at most irq 10
	SB_DMA equ 1 ; in this implementation, supports 0~3 (8-bit sounds DMAC1)
	SB_HDMA equ 5 ; 16-bit sounds dma transfer DMAC2, unused in this implementation
	SB_SAMPLE_RATE equ 8000
	CHANNELS equ 1 ; 1 = mono / 2 = stereo (use only mono, stereo not supported in this implementation)
	SOUND_BUFFER_SIZE equ 80 ; must be divisible by 16
	
	%if SB_IRQ < 8
		INT_OFFSET equ 8
	%else
		INT_OFFSET equ (70h - 8)
	%endif
	
	%if AUDIO_BIT_DEPTH == 8
		DMA_MASK_REGISTER equ 0ah
		DMA_MODE_REGISTER equ 0bh
		DMA_CLEAR_FLIP_FLOP equ 0ch
		DMA_ADDR_REGISTER equ (SB_DMA << 1)
		DMA_COUNT_REGISTER equ ((SB_DMA << 1) + 1)
		%if (SB_DMA == 0) 
			DMA_PAGE_REGISTER equ 87h
		%elif (SB_DMA == 1) 
			DMA_PAGE_REGISTER equ 83h
		%elif (SB_DMA == 2) 
			DMA_PAGE_REGISTER equ 81h
		%elif (SB_DMA == 3) 
			DMA_PAGE_REGISTER equ 82h
		%endif
	%elif AUDIO_BIT_DEPTH == 16
		DMA_MASK_REGISTER equ 0d4h
		DMA_MODE_REGISTER equ 0d6h
		DMA_CLEAR_FLIP_FLOP equ 0d8h
		DMA_ADDR_REGISTER equ ((SB_HDMA << 2) - 1 + 0ch)
		DMA_COUNT_REGISTER equ ((SB_HDMA << 2) + 0ch)
		%if (SB_HDMA == 5) 
			DMA_PAGE_REGISTER equ 8bh
		%elif (SB_HDMA == 6) 
			DMA_PAGE_REGISTER equ 89h
		%elif (SB_HDMA == 7) 
			DMA_PAGE_REGISTER equ 8ah
		%endif
	%endif
	
	FILE_SIZE equ 582370
	
segment code
	
	start:
	
	..start: ; EXE entry point
			mov ax, data
			mov ds, ax
			
			call reset_dsp
			; call setup_irq_dma
			call turn_on_speaker
			call calculate_sound_buffer_page_offset
			
			call fill_next_sound_buffer
			 call fill_next_sound_buffer
			
			call install_sb_isr
			call enable_irq
			call set_sampling_rate
			call program_dma
			call start_playback
			
			; wait for keypress
			mov ah, 0
			int 16h
	.exit:	
			call disable_irq
			call uninstall_sb_isr
			call exit_auto_init
			call turn_off_speaker
			
			mov ax, 4c00h
			int 21h
	
	; --- for debugging purposes ---

	print_ax:
			pusha
			mov bx, ax
			mov cl, 12
			jmp short print_al.next_digit
	print_al:
			pusha
			mov bx, ax
			mov cl, 4
		.next_digit:
			mov ax, bx
			shr ax, cl
			and al, 0fh
			cmp al, 9
			ja .greater
		.below_equal:
			add al, '0'
			jmp short .continue
		.greater:
			add al, ('A' - 10)
		.continue:
			mov ah, 0eh
			int 10h
			sub cl, 4
			jnc .next_digit
		.cr_ln:
			mov al, 0dh ; cr
			int 10h
			mov al, 0ah ; ln
			int 10h
			popa
			ret
	
	; --- sound blaster functions ---
	
	reset_dsp:
			mov dx, SB_BASE_ADDR + 6h
			mov al, 1
			out dx, al
			
			xor ax, ax
		.delay:
			dec ax
			jnz .delay
				
			mov al, 0
			out dx, al
			mov dx, SB_BASE_ADDR + 0eh
		.busy:
			in al, dx
			test al, 10000000b
			jz .busy
			mov dx, SB_BASE_ADDR + 0ah
		.busy2:
			in al, dx
			cmp al, 0aah
			jnz .busy2
			ret
			
	; in: bl = data	
	write_dsp:
			mov dx, SB_BASE_ADDR + 0ch
		.busy:
			in al, dx
			test al, 10000000b
			jnz .busy
			mov dx, SB_BASE_ADDR + 0ch
			mov al, bl
			out dx, al
			ret

; semi-PnP Sound Blasters have only jumpers for the base port with markings IOS0, IOS1.
; you can use this function to setup the IRQ and DMA properly.
; reference: https://retronn.de/imports/soundblaster_config_guide.html
; note: in DOSBOX 0.74-2, DMA setup registers doesn't work ?
setup_irq_dma:
			; reset mixer
			mov dx, SB_BASE_ADDR + 4h
			mov al, 0
			out dx, al
			mov dx, SB_BASE_ADDR + 5h
			mov al, 0
			out dx, al
			
			%if SB_IRQ > 10
				%warning "setup_irq_dma can't configure IRQ above 10 !"
			%endif
			mov dx, SB_BASE_ADDR + 4h
			mov al, 80h ; interrupt setup register ("SoundBlaster.pdf" page 28)
			out dx, al
			mov dx, SB_BASE_ADDR + 5h
			mov al, [cs:.irq_value + SB_IRQ] ; e.g., 00000100b -> irq 7
			out dx, al

			mov dx, SB_BASE_ADDR + 4h
			mov al, 81h ; dma setup register ("SoundBlaster.pdf" page 29)
			out dx, al
			mov dx, SB_BASE_ADDR + 5h
			mov al, 0 ; e.g., 00100010b -> dma 1 & 5
			or al, (1 << SB_HDMA) 
			or al, (1 << SB_DMA) 
			out dx, al

			; master volume
			mov dx, SB_BASE_ADDR + 4h
			mov al, 22h
			out dx, al
			mov dx, SB_BASE_ADDR + 5h
			mov al, 0ffh
			out dx, al
			
			ret
		;      irq -> 0  1  2  3  4  5  6  7  8  9 10
		.irq_value db 0, 0, 1, 0, 0, 2, 0, 4, 0, 0, 8
		
	turn_on_speaker:
			mov bl, 0d1h
			call write_dsp
			ret

	turn_off_speaker:
			mov bl, 0d3h
			call write_dsp
			ret

	exit_auto_init:
			mov bl, 0dah
			call write_dsp
			ret

	set_sampling_rate:
			mov bl, 40h ; time constant
			call write_dsp
			mov bl, (65536 - (256000000 / (CHANNELS * SB_SAMPLE_RATE))) >> 8 ; only hi value of time constant ("SoundBlaster.pdf" page 33)
			call write_dsp
			ret
				
	start_playback:
			; note: for instance, if 8Kb buffer is used, set 4Kb as block size 
			;       so SB will call interrupt twice
			mov bl, 48h ; set block size for 8 bit auto init https://pdos.csail.mit.edu/6.828/2008/readings/hardware/SoundBlaster.pdf pag 48
			call write_dsp
			mov bl, (SOUND_BUFFER_SIZE - 1) & 0ffh ; low
			call write_dsp
			mov bl, (SOUND_BUFFER_SIZE - 1) >> 8 ; high
			call write_dsp
			
			mov bl, 1ch ; <------------------------- autoinit
			call write_dsp 
			ret
			
	; --- buffer ---
			
	; note: this function will set buffer_page and buffer_offset
	calculate_sound_buffer_page_offset:
			mov ax, sound
			mov dx, ax
			shr dx, 12
			shl ax, 4
			add ax, buffer
			mov cx, 0ffffh
			sub cx, ax
			cmp cx, SOUND_BUFFER_SIZE * 2
			jae .size_ok
		.use_next_page:
			mov ax, 0
			inc dx
		.size_ok:
			mov [buffer_page], dx
			mov [buffer_offset], ax
			call print_ax
			mov ax, dx
			call print_ax
			ret

	fill_next_sound_buffer:
			; destination
			mov ax, [buffer_page]
			shl ax, 12
			mov es, ax
			mov di, [buffer_offset]
			add di, [fill_offset]
			
			; source
			mov si, music
			mov ax, data1
			add ax, [sound_seg]
			push ds
			mov ds, ax
			mov cx, SOUND_BUFFER_SIZE
			rep movsb
			pop ds

			inc word [sound_index]
			cmp word [sound_index], FILE_SIZE / SOUND_BUFFER_SIZE
			jbe .below
		.above:
			mov word [sound_index], 0
			mov word [sound_seg], 0
		.below:
		
			mov ax, [sound_index]
			call print_ax
			
			add word [sound_seg], SOUND_BUFFER_SIZE >> 4
			
			cmp word [fill_offset], 0
			jz .zero
		.not_zero:
			mov word [fill_offset], 0
			jmp short .continue
		.zero:
			mov word [fill_offset], SOUND_BUFFER_SIZE
		.continue:
			ret

	; --- IRQ ---
	; references: https://physics.bgu.ac.il/COURSES/SignalNoise/interrupts.pdf
	;             http://stanislavs.org/helppc/8259.html
	; sound blaster ISR (Interruption Service Routine)
	handle_sb_irq: 
			pusha
			push ds
			push es
			
			mov ax, data
			mov ds, ax
			
			;mov ah, 0eh
			;mov al, 'A'
			;int 10h
			
			call fill_next_sound_buffer
			
			; sb ack for 8-bit audio depth
			; note: use port 2xF for 16-bit sound (ref: http://homepages.cae.wisc.edu/~brodskye/sb16doc/sb16doc.html)
			%if AUDIO_BIT_DEPTH == 8
				mov dx, SB_BASE_ADDR + 0eh
				in al, dx
			%elif AUDIO_BIT_DEPTH == 16
				mov dx, SB_BASE_ADDR + 0fh
				in al, dx
			%endif
			
			; EOI
			mov al, 20h
			out 20h, al
			
			; note: if the sound card is on IRQ8-15, you must also write 20h to A0h.
			%if SB_IRQ > 7
				mov al, 20h
				out 0a0h, al
			%endif
			
			pop es
			pop ds
			popa
			iret

	install_sb_isr:
			cli
			mov ax, 0
			mov es, ax
			mov ax, [es:4 * (SB_IRQ + INT_OFFSET)]
			mov [old_int_offset], ax
			mov ax, [es:4 * (SB_IRQ + INT_OFFSET) + 2]
			mov [old_int_seg], ax
			mov word [es:4 * (SB_IRQ + INT_OFFSET)], handle_sb_irq
			mov word [es:4 * (SB_IRQ + INT_OFFSET) + 2], cs
			mov [old_int_seg], ax
			sti
			ret
			
	uninstall_sb_isr:
			cli
			mov ax, 0
			mov es, ax
			mov ax, [old_int_offset]
			mov [es:4 * (SB_IRQ + INT_OFFSET)], ax
			mov ax, [old_int_seg]
			mov [es:4 * (SB_IRQ + INT_OFFSET) + 2], ax
			sti
			ret
	
	; http://www.plantation-productions.com/Webster/www.artofasm.com/DOS/pdf/ch17.pdf (page 1005~1006)
	enable_irq:
			%if SB_IRQ < 8
				mov dx, 21h
				in al, dx
				and al, ~(1 << SB_IRQ) ; must clear bit. E.g., 'and 01111111b' -> enable IRQ 7
				out dx, al
			%else
				mov dx, 0a1h
				in al, dx
				and al, ~(1 << (SB_IRQ - 8)) ; must clear bit. 
				out dx, al
			%endif
			ret
			
	; http://www.plantation-productions.com/Webster/www.artofasm.com/DOS/pdf/ch17.pdf (page 1005~1006)
	disable_irq:
			%if SB_IRQ < 8
				mov dx, 21h
				in al, dx
				or al, (1 << SB_IRQ) ; must set bit. E.g., 'or 10000000b' -> disable IRQ 7 
				out dx, al
				ret
			%else
				mov dx, 0a1h
				in al, dx
				or al, (1 << (SB_IRQ - 8)) ; must set bit. 
				out dx, al
				ret
			%endif

	; --- DMA ---
			
	program_dma:
			mov dx, DMA_MASK_REGISTER  ; write single mask register 
			%if AUDIO_BIT_DEPTH == 8
				mov al, 00000100b + SB_DMA ; disable dma channel 0~3
			%elif AUDIO_BIT_DEPTH == 16
				mov al, 00000100b + (SB_HDMA - 4) ; disable dma channel 4~7
			%endif
			out dx, al 

			mov dx, DMA_CLEAR_FLIP_FLOP ; clear byte pointer flip flop
			mov al, 0h ; any value
			out dx, al 
			
			mov dx, DMA_MODE_REGISTER ; write mode register
			; mov al, 01001000b + DMA ; single cyble playback 
			mov al, 01011000b + SB_DMA ; auto init playback  <----------------------------------- auto init
			out dx, al 

			mov dx, DMA_ADDR_REGISTER ; 8-bit channel 0~3 address / 16-bit channel 4~7 address
			mov al, [buffer_offset] 
			out dx, al ; lo
			mov al, [buffer_offset + 1] 
			out dx, al ; hi 

			mov dx, DMA_COUNT_REGISTER  ; 8-bit channel 0~3 count / 16-bit channel 4~7 count
			mov al, ((SOUND_BUFFER_SIZE * 2 - 1)) & 0ffh
			out dx, al ; lo
			mov al, (SOUND_BUFFER_SIZE * 2 - 1) >> 8
			out dx, al ; hi
			
										; 16 bit dma channel 4~7 page register
			mov dx, DMA_PAGE_REGISTER 	; 8 bit dma channel 0~3 page register
			mov al, [buffer_page] 
			out dx, al 

			mov dx, DMA_MASK_REGISTER  ; write single mask register 
			%if AUDIO_BIT_DEPTH == 8
				mov al, 00000000b + SB_DMA ; enable dma channel 0~3
			%elif AUDIO_BIT_DEPTH == 16
				mov al, 00000000b + (SB_HDMA - 4) ; enable dma channel 4~7
			%endif
			out dx, al 
			
			ret
		.page_register dw 87h, 83h, 81h, 82h, 00h, 8bh, 89h, 8ah

segment data
	buffer_page dw 0
	buffer_offset dw 0
	
	old_int_offset dw 0
	old_int_seg dw 0
	
	sound_index dw 0
	sound_seg dw 0
	fill_offset dw 0
	
segment sound 
	buffer:
			; sampling rate 8Khz = 8000 bytes per sec 
			; 8000 * 1/100 = 80 bytes
			; for auto init, let's use 80 * 2 = 160 bytes buffer size 
			; for each SB interruption, it needs to fill the next 80 bytes buffer
			; note: to solve the DMA page boundary cross problem
			; it's necessary to reserve 160 * 2 = 320 bytes
			times SOUND_BUFFER_SIZE * 4 db 0
			
; 'Level 2' music from:		
; https://opengameart.org/content/5-chiptunes-action
; author: Juhani Junkala (juhani.junkala@musician.org)
segment data1 align=16
	music:
			incbin "level2.raw", 0, 65536
segment data2 align=1
			incbin "level2.raw", 65536, 65536
segment data3 align=1
			incbin "level2.raw", 65536 * 2, 65536
segment data4 align=1
			incbin "level2.raw", 65536 * 3, 65536
segment data5 align=1
			incbin "level2.raw", 65536 * 4, 65536
segment data6 align=1
			incbin "level2.raw", 65536 * 5, 65536
segment data7 align=1
			incbin "level2.raw", 65536 * 6, 65536
segment data8 align=1
			incbin "level2.raw", 65536 * 7, 65536
segment data9 align=1
			incbin "level2.raw", 65536 * 8, 65536

segment stack stack
			resb 256



