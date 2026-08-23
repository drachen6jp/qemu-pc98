/*
 * Minimal PC-9821 BIOS / PCI option ROM, bank 0
*  Copyright (C) 2026 Awe Morris
*  Copyright (C) 2026 drachen6jp
 *
 * The main BIOS maps this bank into the D8000 option window and enters +1Bh
 * for INT 1Ah functions AH=B1h/B4h.  The handler below implements the
 * published PCI BIOS calls directly through configuration mechanism #1.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

.code16
.text

	.equ	PCI_ADDR,		0x0cf8
	.equ	PCI_DATA,		0x0cfc
	.equ	PCI_SUCCESS,		0x00
	.equ	PCI_FUNC_UNSUPPORTED,	0x81
	.equ	PCI_BAD_VENDOR,		0x83
	.equ	PCI_DEVICE_NOT_FOUND,	0x86
	.equ	PCI_BAD_REGISTER,	0x87
	.equ	PCI_SET_FAILED,		0x88
	.equ	PCI_BUFFER_TOO_SMALL,	0x89

	.equ	PCI_IRQ,		14
	.equ	PCI_IRQ_MASK,		(1 << PCI_IRQ)
	.equ	IRQ_TABLE_SIZE,		(irq_table_end - irq_table)

	.globl	_start
_start:
	lret
	nop
	nop
	lret
	nop
	nop
	lret
	nop
	nop

	/* +09 is reserved in the stock PCI bank. */
	.byte	0x00, 0x00, 0x00

//+0Ch
	.byte	0xe9
	.word	initial_pci - . - 2

	/* +0E .. +18 */
	.rept	4
	lret
	nop
	nop
	.endr

	/* +1B: public INT 1Ah AH=B1h/B4h service entry. */
	.byte	0xe9
	.word	pci_int1a - . - 2

	/* +1E */
	lret
	nop
	nop

	/*
	 * +21: private POST helper.  The Xa7 ROM temporarily uses segment 4000h
	 * as scratch space here and clears it before returning.  Configure the
	 * optional QEMU UHCI/EHCI functions before the operating system starts.
	 */
	.byte	0xe9
	.word	pci_post_config - . - 2

	/* +24 and +27 */
	lret
	nop
	nop
	lret
	nop
	nop

	/* +2A .. +2F reserved; +30 and +35 are optional calls. */
	.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.org	0x0030
	lret
	nop
	nop
	.byte	0x00, 0x00
	lret

	.org	0x0100
pci_post_config:
	pushl	%eax
	pushl	%ebx
	pushl	%edx

	/* 00:08.0, Intel 82371SB UHCI: I/O 6000h, bus master, IRQ 14. */
	movw	$PCI_ADDR, %dx
	movl	$0x80004000, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inl	%dx, %eax
	cmpl	$0x70208086, %eax
	jne	1f
	movw	$PCI_ADDR, %dx
	movl	$0x80004020, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movl	$0x00006001, %eax
	outl	%eax, %dx
	movw	$PCI_ADDR, %dx
	movl	$0x80004004, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movw	$0x0005, %ax		/* I/O space and bus master */
	outw	%ax, %dx
	movw	$PCI_ADDR, %dx
	movl	$0x8000403c, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movb	$PCI_IRQ, %al
	outb	%al, %dx
1:
	/* 00:0d.0, Intel 82801D EHCI: MMIO F1000000h, master, IRQ 14. */
	movw	$PCI_ADDR, %dx
	movl	$0x80006800, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inl	%dx, %eax
	cmpl	$0x24cd8086, %eax
	jne	2f
	movw	$PCI_ADDR, %dx
	movl	$0x80006810, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movl	$0xf1000000, %eax
	outl	%eax, %dx
	movw	$PCI_ADDR, %dx
	movl	$0x80006804, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movw	$0x0006, %ax		/* memory space and bus master */
	outw	%ax, %dx
	movw	$PCI_ADDR, %dx
	movl	$0x8000683c, %eax
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movb	$PCI_IRQ, %al
	outb	%al, %dx
2:
	movw	$PCI_ADDR, %dx
	xorl	%eax, %eax
	outl	%eax, %dx
	popl	%edx
	popl	%ebx
	popl	%eax
	lret

initial_pci:
	pushl	%eax
	pushl	%ebx
	pushl	%edx
	pushl	%ecx
	pushl	%esi
	pushl	%edi
	movl	$0x80000000,%eax
	xorl	%esi,%esi
	movb	$0x1,%ah
1:
	shlw	$3, %ax
	movb	$0xe, %al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inb	%dx, %al
	cmpb	$1, %al	//PCI- to PCI Bridge
	je	findbridge
2:
	shrw	$3, %ax
	incb	%ah
	cmpb	$31, %ah
	ja	hostend
	jmp	1b

findbridge:
	incl	%esi
	cmpw	$3, %si		//1段目のブリッジは3つ分くらいしかIOがない かも
	ja	2b
	movb	$0x1c,%al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	push	%eax
	cmpw	$1, %si
	jne	2f
	movw	$0xc0c0, %ax		//bridge 1 IO=C000-CFFF
	jmp	4f
2:
	cmpw	$2, %si
	jne	3f
	movw	$0x7070, %ax		//bridge 2 IO=7000-7FFF
	jmp	4f
3:
	movw	$0x6060, %ax		//bridge 3 IO=6000-6FFF
4:
	outw	%ax, %dx
	popl	%eax
	pushl	%eax
	movw	$PCI_ADDR, %dx
	movb	$0x18, %al
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	cmpw	$1, %si
	jne	2f
	movl	$0x010100, %eax	//busnumber = 1
	jmp	4f
2:
	cmpw	$2, %si
	jne	3f
	movl	$0x020200, %eax	//busnumber = 2
	jmp	4f
3:
	movl	$0x030300, %eax	//busnumber = 3
4:
	outl	%eax, %dx
	pop	%eax
	push	%eax
	movw	$PCI_ADDR, %dx
	popl	%eax
	pushl	%eax
	movb	$0x4, %al
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movb	$0x7, %al		//Enable IO MEM BM
	outb	%al, %dx
	pop	%eax
	push	%eax
	movw	$PCI_ADDR, %dx
	movb	$0x20, %al
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	cmpw	$1, %si
	jne	2f
	movl	$0x80008000, %eax	//Memory 80000000h-800fffff
	jmp	4f
2:
	cmpw	$2, %si
	jne	3f
	movl	$0x80108010, %eax	//Memory 80100000h-801fffff
	jmp	4f
3:
	movl	$0x80208020, %eax	//Memory 80200000h-802fffff
4:
	outl	%eax, %dx
	pop	%eax
	push	%eax
	movw	$PCI_ADDR, %dx
	movb	$0x24, %al
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	cmpw	$1, %si
	jne	2f
	movl	$0x80018001, %eax	//PrefetchMemory 80000000h-800fffff
	jmp	4f
2:
	cmpw	$2, %si
	jne	3f
	movl	$0x80118011, %eax	//PrefetchMemory 80100000h-801fffff
	jmp	4f
3:
	movl	$0x80218021, %eax	//PrefetchMemory 80200000h-802fffff
4:
	outl	%eax, %dx
	pop	%eax
	shrw	$3, %ax
	incb	%ah
	jmp	1b

hostend:
	shll	$16,%esi
	movw	$0xe001, %si
	movl	$0xe0000000, %edi
	movl	$0x80000000, %eax
	movb	$0x1,%ah
	pushl	%eax
1:
	shlw	$3, %ax
	movb	$0, %al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inw	%dx, %ax
	cmpw	$0xffff, %ax
	jne	findcard
2:
	popl	%eax
	incb	%ah
	pushl	%eax
	cmpb	$32, %ah
	jb	1b	
	popl	%eax
	jmp	1f
	
1:
	popl	%edi
	popl	%esi
	popl	%ecx
	popl	%edx
	popl	%ebx
	popl	%eax
	lret

findcard:
	popl	%eax
	pushl	%eax
	cmpb	$6, %ah	//CbusBridge
	je	2b
	cmpb	$7, %ah	//98CoreGRPH
	je	2b
	shlw	$3, %ax
	movb	$0xe, %al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inb	%dx, %al
	cmpb	$0, %al
	jne	2b
	popl	%eax
	pushl	%eax
	shlw	$3, %ax
	movb	$0x4, %al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	movb	$0x7, %al		//Enable IO MEM BM
	outb	%al, %dx
	popl	%eax
	pushl	%eax
	shlw	$3, %ax
	movb	$0x3c, %al
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx	
	movw	$PCI_DATA, %dx
	inw	%dx, %ax
	cmpb	$0,%ah
	je	1f
	movb	$PCI_IRQ, %al		//IRQ 14
	outb	%al, %dx
1:
	popl	%eax
	pushl	%eax
	shlw	$3, %ax
	movb	$0xc, %al
6:
	addb	$0x4, %al
	pushl	%eax
	call	7f
	popl	%eax
	cmpb	$0x24, %al
	jb	6b
	jmp	2b

7:
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_DATA, %dx
	inb	%dx, %al
	test	$1,%al
	jne	3f
	call	8f
	ret
3:
	call	9f
	ret
8:
	movl	$0xffffffff, %eax
	outl	%eax, %dx
	inl	%dx, %eax
	cmpl	$0, %eax
	je	6f
	andl	$0xfffffff0, %eax
	movl	%eax, %ecx
	not	%ecx
	inc	%ecx
	addl	%ecx, %edi
	movl	%edi, %eax
	outl	%eax, %dx
	addl	%ecx, %edi
6:
	ret
9:
	movl	$0xffff, %eax
	outl	%eax, %dx
	inl	%dx, %eax
	movl	$0x10001, %ecx
	subl	%eax,%ecx
	addw	%cx, %si
	xorl	%eax, %eax
	movw	%si, %ax
	outl	%eax, %dx
	addw	%cx, %si
	ret

	/* Published signature retained at the same bank offset as the Xa7 ROM. */
	.org	0x1102
	.ascii	"$PCI"

	.org	0x2000
pci_int1a:
	pushw	%bp
	movw	%sp, %bp
	pushw	%ax			/* preserve the B1xx subfunction in AL */
	pushw	%ds
	pushw	%es
	pushw	%si
	pushw	%di
	cld

	cmpb	$0xb1, %ah
	je	pci_bios
	cmpb	$0xb4, %ah
	je	pci_autoconfig
	jmp	pci_unsupported

pci_bios:
	cmpb	$0x01, %al
	je	pci_present
	cmpb	$0x02, %al
	je	pci_find_device
	cmpb	$0x03, %al
	je	pci_find_class
	cmpb	$0x08, %al
	je	pci_read_byte
	cmpb	$0x09, %al
	je	pci_read_word
	cmpb	$0x0a, %al
	je	pci_read_dword
	cmpb	$0x0b, %al
	je	pci_write_byte
	cmpb	$0x0c, %al
	je	pci_write_word
	cmpb	$0x0d, %al
	je	pci_write_dword
	cmpb	$0x0e, %al
	je	pci_get_irq_routing
	cmpb	$0x0f, %al
	je	pci_set_irq

pci_unsupported:
	movb	$PCI_FUNC_UNSUPPORTED, %ah
	jmp	pci_error

pci_autoconfig:
	testb	%al, %al
	jne	pci_autoconfig_unsupported
	xorl	%eax, %eax
	movw	$0x0208, %bx
	movw	$0x0002, %cx
	movl	$0x47464341, %edx	/* "ACFG" */
	movw	$0x001f, -8(%bp)	/* returned after the saved SI is popped */
	jmp	pci_success

pci_autoconfig_unsupported:
	movw	$0x0051, %ax		/* function not supported */
	jmp	pci_error

pci_present:
	movw	$0x0210, %bx		/* PCI BIOS version 2.10 */
	xorb	%cl, %cl		/* last PCI bus */
	movl	$0x20494350, %edx	/* "PCI " */
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_find_device:
	cmpw	$0xffff, %dx
	je	pci_bad_vendor
	xorw	%bx, %bx		/* bus 0, devfn 0 */
1:
	pushw	%cx
	pushw	%dx
	xorw	%di, %di		/* register 0 */
	call	cfg_read_dword
	popw	%dx
	popw	%cx
	cmpw	%dx, %ax
	jne	2f
	shrl	$16, %eax
	cmpw	%cx, %ax
	jne	2f
	testw	%si, %si
	je	pci_found
	decw	%si
2:
	incb	%bl
	jnz	1b
	jmp	pci_not_found

pci_find_class:
	andl	$0x00ffffff, %ecx
	xorw	%bx, %bx
	pushw	%dx
1:
	pushl	%ecx
	movw	$0x0008, %di
	call	cfg_read_dword
	shrl	$8, %eax
	popl	%ecx
	andl	$0x00ffffff, %eax
	cmpl	%ecx, %eax
	jne	2f
	testw	%si, %si
	je	pci_class_found
	decw	%si
2:
	incb	%bl
	jnz	1b
	popw	%dx
	jmp	pci_not_found

pci_class_found:
	popw	%dx
pci_found:
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_bad_vendor:
	movb	$PCI_BAD_VENDOR, %ah
	jmp	pci_error

pci_not_found:
	movb	$PCI_DEVICE_NOT_FOUND, %ah
	jmp	pci_error

pci_read_byte:
	cmpw	$0x00ff, %di
	ja	pci_bad_register
	pushw	%dx
	call	cfg_address
	movw	%di, %ax
	andw	$3, %ax
	addw	$PCI_DATA, %ax
	movw	%ax, %dx
	inb	%dx, %al
	movb	%al, %cl
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_read_word:
	cmpw	$0x00fe, %di
	ja	pci_bad_register
	testw	$1, %di
	jnz	pci_bad_register
	pushw	%dx
	call	cfg_address
	movw	%di, %ax
	andw	$2, %ax
	addw	$PCI_DATA, %ax
	movw	%ax, %dx
	inw	%dx, %ax
	movw	%ax, %cx
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_read_dword:
	cmpw	$0x00fc, %di
	ja	pci_bad_register
	testw	$3, %di
	jnz	pci_bad_register
	pushw	%dx
	call	cfg_read_dword
	movl	%eax, %ecx
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_write_byte:
	cmpw	$0x00ff, %di
	ja	pci_bad_register
	pushw	%dx
	call	cfg_address
	movw	%di, %ax
	andw	$3, %ax
	addw	$PCI_DATA, %ax
	movw	%ax, %dx
	movb	%cl, %al
	outb	%al, %dx
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_write_word:
	cmpw	$0x00fe, %di
	ja	pci_bad_register
	testw	$1, %di
	jnz	pci_bad_register
	pushw	%dx
	call	cfg_address
	movw	%di, %ax
	andw	$2, %ax
	addw	$PCI_DATA, %ax
	movw	%ax, %dx
	movw	%cx, %ax
	outw	%ax, %dx
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

pci_write_dword:
	cmpw	$0x00fc, %di
	ja	pci_bad_register
	testw	$3, %di
	jnz	pci_bad_register
	pushw	%dx
	pushl	%ecx
	call	cfg_address
	popl	%eax
	movw	$PCI_DATA, %dx
	outl	%eax, %dx
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success

/*
 * PCI BIOS B10Eh.  The 16-bit interface points ES:DI at:
 *     word buffer_size; dword buffer_far_pointer
 * The Xa7 exposes three 16-byte routes for its onboard/physical slots.
 * This machine wires every PCI INTx pin to PC-98 IRQ 14, so advertise that
 * fixed route instead of the mutable routing registers used by real boards.
 */
pci_get_irq_routing:
	testw	%bx, %bx
	jnz	pci_unsupported
	cmpw	$IRQ_TABLE_SIZE, %es:(%di)
	jb	1f
	movw	$IRQ_TABLE_SIZE, %es:(%di)
	movw	%es:2(%di), %bx
	movw	%es:4(%di), %ax
	movw	%ax, %es
	movw	%cs, %ax
	movw	%ax, %ds
	movw	$irq_table, %si
	movw	%bx, %di
	movw	$IRQ_TABLE_SIZE, %cx
	rep	movsb
	movw	$PCI_IRQ_MASK, %bx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success
1:
	movw	$IRQ_TABLE_SIZE, %es:(%di)
	movb	$PCI_BUFFER_TOO_SMALL, %ah
	jmp	pci_error

/*
 * PCI BIOS B10Fh.  QEMU's PC-9821 host bridge has a fixed INTx route, so a
 * request succeeds only for IRQ 14.  Also mirror it to Interrupt Line (3Ch)
 * for software that subsequently reads configuration space.
 */
pci_set_irq:
	cmpb	$0x0a, %cl
	jb	1f
	cmpb	$0x0d, %cl
	ja	1f
	cmpb	$PCI_IRQ, %ch
	jne	1f
	movw	$0x0000, %di
	pushw	%dx
	call	cfg_read_dword
	cmpw	$0xffff, %ax
	je	2f
	movw	$0x003c, %di
	call	cfg_address
	movw	$PCI_DATA, %dx
	movb	%ch, %al
	outb	%al, %dx
	call	cfg_finish
	popw	%dx
	movb	$PCI_SUCCESS, %ah
	jmp	pci_success
2:
	popw	%dx
1:
	movb	$PCI_SET_FAILED, %ah
	jmp	pci_error

pci_bad_register:
	movb	$PCI_BAD_REGISTER, %ah

pci_error:
	orb	$0x01, 6(%bp)
	jmp	pci_return

pci_success:
	andb	$0xfe, 6(%bp)

pci_return:
	/*
	 * The PCI BIOS status is returned in AH while AL continues to identify
	 * the B1xx subfunction.  The stock ROM preserves it even when config
	 * reads use EAX internally.  B4xx has its own full-AX return values.
	 */
	cmpb	$0xb1, -1(%bp)
	jne	1f
	movb	-2(%bp), %al
1:
	popw	%di
	popw	%si
	popw	%es
	popw	%ds
	addw	$2, %sp
	popw	%bp
	iret

/*
 * Select BX (BH=bus, BL=devfn), DI register in configuration mechanism #1.
 */
cfg_address:
	movl	$0x80000000, %eax
	movzbl	%bh, %edx
	shll	$16, %edx
	orl	%edx, %eax
	movzbl	%bl, %edx
	shll	$8, %edx
	orl	%edx, %eax
	movzwl	%di, %edx
	andl	$0xfc, %edx
	orl	%edx, %eax
	movw	$PCI_ADDR, %dx
	outl	%eax, %dx
	ret

cfg_read_dword:
	call	cfg_address
	movw	$PCI_DATA, %dx
	inl	%dx, %eax
	call	cfg_finish
	ret

/*
 * End a mechanism-1 cycle by clearing the enable bit in CF8h.  The Xa7
 * PCI BIOS does this after every access; leaving it asserted changes how
 * later firmware/OS probes see the configuration latch.
 */
cfg_finish:
	pushl	%eax
	pushw	%dx
	movw	$PCI_ADDR, %dx
	inl	%dx, %eax
	andl	$0x7fffffff, %eax
	outl	%eax, %dx
	popw	%dx
	popl	%eax
	ret

	/* bus, devfn, four (link, IRQ bitmap) pairs, slot, reserved */
irq_table:
	.byte	0x00, 0x40
	.byte	0x01
	.word	PCI_IRQ_MASK
	.byte	0x00
	.word	0x0000
	.byte	0x00
	.word	0x0000
	.byte	0x00
	.word	0x0000
	.byte	0x00, 0x00

	.byte	0x00, 0x68
	.byte	0x01
	.word	PCI_IRQ_MASK
	.byte	0x02
	.word	PCI_IRQ_MASK
	.byte	0x03
	.word	PCI_IRQ_MASK
	.byte	0x04
	.word	PCI_IRQ_MASK
	.byte	0x01, 0x00

	.byte	0x00, 0x70
	.byte	0x02
	.word	PCI_IRQ_MASK
	.byte	0x03
	.word	PCI_IRQ_MASK
	.byte	0x04
	.word	PCI_IRQ_MASK
	.byte	0x01
	.word	PCI_IRQ_MASK
	.byte	0x02, 0x00
irq_table_end:

	.org	0x8000
