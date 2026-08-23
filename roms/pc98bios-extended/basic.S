/*
 * Minimal free PC-98 ROM BASIC compatibility stub.
 * Copyright (C) 2026 Awe Morris
 *
 * This is an independently written compatibility stub.  It contains no
 * NEC or Microsoft ROM code or data.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

.code16
.text

	.equ	BASIC_RAM_SEG,		0x9000
	.equ	BASIC_STACK_SEG,	0x8f00
	.equ	BANKFLIP_PORT,		0x043d

	.equ	BASIC_MAGIC_OFFSET,	0x0040
	.equ	BASIC_ENTRY_OFFSET,	0x0050

	/*
	 * The bank is visible at F800:0000.  Copy the active part to ordinary
	 * RAM before restoring main-BIOS bank 7; changing the bank while still
	 * fetching instructions from it would immediately replace our code.
	 */
	.org	0
	.globl	_start
_start:
	cli
	cld
	pushw	%cs
	popw	%ds
	movw	$BASIC_RAM_SEG, %ax
	movw	%ax, %es
	xorw	%si, %si
	xorw	%di, %di
	movw	$(image_end - _start + 1) / 2, %cx
	rep	movsw
	ljmp	$BASIC_RAM_SEG, $(ram_entry - _start)

	/*
	 * The compatibility BIOS checks this signature before entering bank 2.
	 * Keep it at a fixed offset so an unrelated pc98bank2.bin is not
	 * mistaken for this independently written stub.
	 */
	.org	BASIC_MAGIC_OFFSET
basic_magic:
	.ascii	"PC98BAS1"

	.org	BASIC_ENTRY_OFFSET
ram_entry:
	cli
	movw	$BASIC_STACK_SEG, %ax
	movw	%ax, %ss
	movw	$0xfffe, %sp
	pushw	%cs
	popw	%ds

	/* Restore the permanently used main-BIOS bank before calling INT 18h. */
	movw	$BANKFLIP_PORT, %dx
	movb	$0x02, %al
	outb	%al, %dx

	movb	$0, cursor_row
	movb	$0, cursor_col
	movb	$0x20, %dl
	movb	$0xe1, %dh
	movb	$0x16, %ah
	int	$0x18
	movb	$0x11, %ah
	int	$0x18
	sti

	movw	$prompt, %si
	call	puts

	/*
	 * This first increment deliberately implements no BASIC language.
	 * Accept and echo only the advertised decimal file-count input, then
	 * display the compatibility banner and remain at the Ok prompt.
	 */
	movb	$0, input_value
	movb	$0, input_digits
input_loop:
	xorb	%ah, %ah
	int	$0x18
	cmpb	$0x0d, %al
	je	input_done
	cmpb	$0x08, %al
	je	input_backspace
	cmpb	$'0', %al
	jb	input_loop
	cmpb	$'9', %al
	ja	input_loop
	cmpb	$2, input_digits
	jae	input_loop

	movb	%al, %cl
	subb	$'0', %al
	movb	%al, %bl
	movb	input_value, %al
	movb	$10, %ah
	mulb	%ah
	addb	%bl, %al
	cmpb	$15, %al
	ja	input_loop
	movb	%al, input_value
	incb	input_digits
	movb	%cl, %al
	call	putc
	jmp	input_loop

input_backspace:
	cmpb	$0, input_digits
	je	input_loop
	decb	input_digits
	movb	input_value, %al
	xorb	%ah, %ah
	movb	$10, %bl
	divb	%bl
	movb	%al, input_value
	call	erase_last
	jmp	input_loop

input_done:
	call	newline
	movw	$banner, %si
	call	puts

idle:
	sti
	hlt
	jmp	idle

puts:
	lodsb
	testb	%al, %al
	jz	1f
	call	putc
	jmp	puts
1:
	ret

putc:
	cmpb	$0x0a, %al
	je	newline
	pushw	%ax
	call	cursor_offset
	popw	%ax
	pushw	%ax
	movw	$0xa000, %ax
	movw	%ax, %es
	popw	%ax
	xorb	%ah, %ah
	movw	%ax, %es:(%di)
	movb	$0xe1, %es:0x2000(%di)
	incb	cursor_col
	cmpb	$80, cursor_col
	jb	update_cursor
	movb	$0, cursor_col
	incb	cursor_row
	jmp	update_cursor

newline:
	movb	$0, cursor_col
	incb	cursor_row
	cmpb	$25, cursor_row
	jb	update_cursor
	movb	$24, cursor_row
	jmp	update_cursor

erase_last:
	cmpb	$0, cursor_col
	je	update_cursor
	decb	cursor_col
	call	cursor_offset
	movw	$0xa000, %ax
	movw	%ax, %es
	movw	$0x0020, %es:(%di)
	movb	$0xe1, %es:0x2000(%di)
	jmp	update_cursor

cursor_offset:
	xorw	%ax, %ax
	movb	cursor_row, %al
	movw	$160, %bx
	mulw	%bx
	movw	%ax, %di
	xorw	%ax, %ax
	movb	cursor_col, %al
	shlw	$1, %ax
	addw	%ax, %di
	ret

update_cursor:
	call	cursor_offset
	movw	%di, %dx
	movb	$0x13, %ah
	int	$0x18
	ret

prompt:
	.asciz	"How many files(0-15)? "
banner:
	.ascii	"N-88 BASIC(86) compatible stub version 2.0\n"
	.ascii	"Copyright (C) 2026 PC-9800 Lovers\n"
	.ascii	"641668 Bytes free\n"
	.asciz	"Ok\n"

cursor_row:
	.byte	0
cursor_col:
	.byte	0
input_value:
	.byte	0
input_digits:
	.byte	0

image_end:

	.org	0x8000
