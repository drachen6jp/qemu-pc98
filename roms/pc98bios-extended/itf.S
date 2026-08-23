/*
 * Minimal PC-9821 BIOS / ITF, bank 4
 * Copyright (C) 2026 Awe Morris
 *
 * The bank is paged into the 0xF8000-0xFFFFF window and is the bank selected
 * out of reset, so the CPU's reset vector at 0xFFFF0 lands in this image at
 * offset 0x7FF0.  From there the NEC firmware jumps to F800:4000, which is
 * where the ITF proper begins; that entry address is kept because option ROMs
 * and the main BIOS both assume it.
 *
 * Responsibilities of this stage: bring the CPU to a known state, set up the
 * BIOS work area, then page the main BIOS into the window and hand control to
 * its own reset entry.
 *
 * Ports used here:
 *   0x43D  window bank flip: 0x00/0x10/0x18 selects ITF, 0x02/0x12 the BIOS
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

.code16
.text

	.equ	BANKFLIP_PORT,	0x43d
	.equ	BANKFLIP_BIOS,	0x02

	/* Option ROM gate: bit 4 shows the internal disk BIOS at 0xD8000. */
	.equ	ROMGATE_PORT,	0x53d
	.equ	ROMGATE_IDE,	0x10

	/* BIOS work-area cells this firmware is responsible for. */
	.equ	WA_MEMSIZE,	0x0401
	.equ	WA_PRINTER,	0x0458
	.equ	WA_KEYBOARD,	0x0481
	.equ	WA_CLOCK,	0x0501
	.equ	WA_EXTMEM,	0x0594
	.equ	WA_EXPANSION,	0x05b3
	.equ	WA_IDE_PROBE,	0x05ba

	/* A20 mask control: write 0x02 to release the line, 0x03 to mask it. */
	.equ	A20_CMD,	0xf6

	/* 15-16 MiB system-space control: bit 2 set exposes ordinary RAM. */
	.equ	SYS16M_CTRL,	0x43b
	.equ	SYS16M_DISABLE,	0x04

	/*
	 * Memory probe: an arbitrary signature, and a ceiling of 496 MiB above
	 * the 16 MiB line -- 512 MiB total, more than any PC-98 shipped with.
	 */
	.equ	MEM_PROBE_SIG,	0x39385043
	.equ	MEM_PROBE_MAX,	496

	/* Software DIP switch bank: control register, data at 0xXX1E. */
	.equ	SDIP_CTRL,	0x8f1f

	/* Flat data selector in the scratch GDT used for the memory probe. */
	.equ	GDT_FLAT_DS,	0x08
	.equ	GDT_REAL_DS,	0x10
	.equ	GDT_CODE16,	0x18
	.equ	GDT_RAM,	0x0600

	/* Character generator window: code, scan line and pattern data. */
	.equ	CG_CODE_LO,	0xa1
	.equ	CG_CODE_HI,	0xa3
	.equ	CG_LINE,	0xa5
	.equ	CG_PATTERN,	0xa9

	.equ	PCI_CONF_ADDR,	0xcf8
	.equ	PCI_CONF_DATA,	0xcfc

	/*
	 * Host bridge register 0x68.  Bit 4 of byte 0x69 -- bit 12 of the
	 * dword -- opens the IDE probe latch for writing.
	 */
	.equ	PCI_HOST_REG68,		0x80000068
	.equ	PCI_BIOS_PROBE_GATE,	0x00001000

	/*
	 * Host bridge register 0x64: its top byte gates the option ROM's
	 * shadow RAM, one 4 KiB page per bit -- 0x10 for 0xDA000, 0x20 for
	 * 0xDB000, 0x80 for 0xDC000-0xDFFFF.
	 */
	.equ	PCI_HOST_REG64,		0x80000064
	.equ	PCI_D000_SHADOW_B,	0x20000000

	/* The latch sits at 0xF8E90, which is this bank's offset 0x0E90. */
	.equ	F8E90_OFFSET,	0x0e90

	/* Candidate IDE drives handed to the chipset. */
	.equ	IDE_PROBE_MASK,	0x01

	/*
	 * Calendar clock periodic interrupt: the rate register, and the mode
	 * bits (0 = 1/64 s, 1 = 1/32 s, 2 = off, 3 = 1/16 s).
	 */
	/* Analog palette: entry select, then the three colour components. */
	.equ	PAL_INDEX,	0xa8
	.equ	PAL_GREEN,	0xaa
	.equ	PAL_RED,	0xac
	.equ	PAL_BLUE,	0xae

	/* Text GDC command and parameter ports, and its PRAM-load command. */
	.equ	GDC_TEXT_CMD,	0x62
	.equ	GDC_TEXT_PARAM,	0x60
	.equ	GDC_CMD_SCROLL,	0x70

	/*
	 * Display mode flip-flop: register number in bits 3:1, value in bit 0.
	 * Register 7 is the master display enable.
	 */
	.equ	MODE_FF1,	0x68
	.equ	MODE1_DISP_ON,	0x0f

	/* IDE device control register, and its software-reset bit. */
	.equ	IDE_DEV_CTL,	0x74c
	.equ	IDE_CTL_SRST,	0x06

	/* PC-98 wait-state port: a dummy write burns one bus cycle. */
	.equ	WAIT_IO,	0x5f

	.equ	CAL_TICK_CTL,	0x128
	.equ	CAL_TICK_32HZ,	0x01

	/* System 8255 PPI: port C carries the shutdown/resume flags. */
	.equ	SYSPPI_PORT_C,	0x35

	/* Work-area cell holding the stack the BIOS wants to resume on. */
	.equ	RESUME_SP,	0x0404
	.equ	RESUME_SS,	0x0406

	/* 8259 pair: master at 0x00/0x02, slave at 0x08/0x0A. */
	.equ	PIC1_CMD,	0x00
	.equ	PIC1_DATA,	0x02
	.equ	PIC2_CMD,	0x08
	.equ	PIC2_DATA,	0x0a

	/* Linear address the 32 KiB bank window sits at. */
	.equ	ROM_WINDOW_BASE, 0xf8000

	.equ	ITF_ENTRY,	0x4000
	.equ	RESET_VECTOR,	0x7ff0
	.equ	BANK_SIZE,	0x8000

	/*
	 * The stack lives just under the BIOS work area at 0:0400.  Real
	 * hardware parks it there during POST for the same reason: nothing
	 * else may use that space until the boot loader runs.
	 */
	.equ	POST_STACK,	0x0400

	/*
	 * Where the bank-flip stub lives.  This address is not free to choose:
	 * the disk BIOS option ROM sets AL and DX and then jumps straight to
	 * 0000:04F8 to switch banks (bank3 offset 0x1ad4), so the stub the ITF
	 * leaves behind is part of the interface other ROMs rely on.
	 */
	.equ	TRAMPOLINE,	0x04f8

	.org	ITF_ENTRY
	.globl	_start
_start:
	cli
	cld

	xorw	%ax, %ax
	movw	%ax, %ds

	/*
	 * Not every entry here is a power-on.  The main BIOS leaves protected
	 * mode the 80286 way, by resetting the CPU, and the machine turns that
	 * into a CPU-only reset as long as the shutdown flag is disarmed --
	 * RAM keeps its contents and execution restarts at this address.
	 *
	 * Port 0x35 is the system 8255's port C; bit 7 clear marks that case.
	 * The BIOS has parked the address to continue at on a stack of its own
	 * choosing and left the pointer to it in the work area, so switch to
	 * that stack and return into it.  Running a full POST instead would
	 * restart the BIOS from the beginning, forever.
	 */
	inb	$SYSPPI_PORT_C, %al
	testb	$0x80, %al
	jnz	cold_start
	movw	RESUME_SS, %ss
	movw	RESUME_SP, %sp
	lret

cold_start:
	/*
	 * Reload every segment register from a known value.  The CPU comes out
	 * of reset with CS pointing at the top of the address space; the rest
	 * are already zero, but a warm boot can reach here with anything.
	 */
	xorw	%ax, %ax
	movw	%ax, %es
	movw	%ax, %ss
	movw	$POST_STACK, %sp

	call	pic_init

	/*
	 * The supported machine configuration has no device in the 15-16 MiB
	 * system-space aperture.  Disable the hole before sizing memory and keep
	 * this hardware state in lockstep with the BIOS work-area value written
	 * by workarea_init.
	 */
	movb	$SYS16M_DISABLE, %al
	movw	$SYS16M_CTRL, %dx
	outb	%al, %dx
	call	workarea_init

	/* Source of the table and the copy below is this ROM. */
	movw	%cs, %ax
	movw	%ax, %ds

	call	disp_init
	call	pal_init
	call	pit_init
	call	pci_init
	call	ide_probe_latch
	call	memsw_init
	call	sdip_init
	call	wa_seed

	/*
	 * Page the internal disk BIOS into the D000 window and leave it there.
	 * The main BIOS decides whether to shadow that segment by looking at
	 * what is in it, so with the window empty it leaves the shadow off and
	 * never gets a working disk BIOS.
	 */
	movb	$ROMGATE_IDE, %al
	movw	$ROMGATE_PORT, %dx
	outb	%al, %dx

	/*
	 * Back the disk BIOS's 0xDB000 page with shadow RAM.  Host bridge
	 * register 0x64 gates the option ROM's shadow one 4 KiB page at a
	 * time, and bit 0x20 of its top byte covers that page; with the gate
	 * closed the disk BIOS finds ROM where it expects its own writable
	 * work area and mis-detects the drives.
	 */
	movl	$PCI_HOST_REG64, %eax
	movw	$PCI_CONF_ADDR, %dx
	outl	%eax, %dx
	movl	$PCI_D000_SHADOW_B, %eax
	movw	$PCI_CONF_DATA, %dx
	outl	%eax, %dx

	/*
	 * Hand the text GDC its display partitions.  Until its parameter RAM
	 * is loaded the controller has no display area to scan, so the screen
	 * body stays blank even with everything else enabled -- only the
	 * function-key line, which is drawn from a fixed address, shows up.
	 * The four partitions are start address and length pairs; these are
	 * the values the NEC firmware programs for an 80x25 text screen.
	 */
	movb	$GDC_CMD_SCROLL, %al
	outb	%al, $GDC_TEXT_CMD
	movw	$gdc_pram, %si
	movw	$(gdc_pram_end - gdc_pram), %cx
1:
	lodsb
	outb	%al, $GDC_TEXT_PARAM
	loop	1b

	/*
	 * Turn the display on.  The mode flip-flop at 0x68 takes a register
	 * number in bits 3:1 and the new value in bit 0, so 0x0F sets the
	 * master display-enable.  Nothing else switches it on: with it clear
	 * the emulated GDC scans out nothing at all, and the machine boots to
	 * a black screen even though the text plane is filled in correctly.
	 */
	movb	$MODE1_DISP_ON, %al
	outb	%al, $MODE_FF1

	/*
	 * Pulse the IDE channel's software reset.  An ATA device reports 0x01
	 * in its error register once it has run its power-on diagnostic, and
	 * the disk BIOS uses precisely that to decide a drive is usable: a
	 * device that has never been reset reads 0x00 there and is rejected
	 * before it is ever identified, leaving the drive geometry empty.
	 */
	movw	$IDE_DEV_CTL, %dx
	movb	$IDE_CTL_SRST, %al
	outb	%al, %dx
	outb	%al, $WAIT_IO
	outb	%al, $WAIT_IO
	xorb	%al, %al
	outb	%al, %dx
	outb	%al, $WAIT_IO

	/*
	 * Restart the calendar clock's periodic interrupt so the BIOS starts
	 * its first timed wait from a known phase.  Writing the rate register
	 * also zeroes the tick counter and drops any pending request; leaving
	 * it free-running means the BIOS sometimes samples just after a tick
	 * and times out instead, which makes the same image boot to different
	 * places from one run to the next.  Mode 1 is the 1/32 s rate the
	 * machine powers up with.
	 */
	movb	$CAL_TICK_32HZ, %al
	movw	$CAL_TICK_CTL, %dx
	outb	%al, %dx

	/*
	 * Paging the BIOS in replaces the memory this code is running from, so
	 * the bank flip cannot be executed out of the ITF bank: the fetch after
	 * the OUT would already come from the new bank.  Copy the flip and the
	 * far jump into low RAM and run them from there.  The NEC ITF hands
	 * over the same way, through a stub it plants at 0000:04F8.
	 */
	movb	$BANKFLIP_BIOS, %al
	movw	$BANKFLIP_PORT, %dx
	movw	$bankflip_stub, %si
	movw	$TRAMPOLINE, %di
	movw	$(bankflip_stub_end - bankflip_stub), %cx
	rep	movsb
	ljmp	$0x0000, $TRAMPOLINE

/*
 * Fill in the parts of the BIOS work area the firmware owns.
 *
 * The BIOS reads these rather than probing for itself, and derives the
 * chipset's DRAM configuration from them; leaving them zero makes it
 * program the host bridge for no extended memory at all.
 *
 * DS must be zero.  Extended memory is sized by probing through a segment
 * left with a 4 GiB limit, so this has to run before anything reloads FS.
 */
workarea_init:
	/*
	 * Port 43Bh has disabled the unused 15-16 MiB system window, making
	 * the full range implemented below 16 MiB available as RAM.  The
	 * memory controller updates WA_MEMSIZE when SYS16M_CTRL is written;
	 * preserve that hardware-derived value.  Hard-coding 78h here made
	 * configurations with less than 16 MiB advertise nonexistent RAM.
	 */
	/* system clock, 5 MHz series */
	movb	$0x24, WA_CLOCK
	/* the emulated keyboard speaks the PC-9801-119 extended command set */
	orb	$0x40, WA_KEYBOARD
	/* no second printer port, no expansion parity */
	andb	$~0x06, WA_PRINTER
	andb	$~0xe0, WA_EXPANSION

	/* candidate IDE drives; the chipset narrows this to the real ones */
	movb	$IDE_PROBE_MASK, WA_IDE_PROBE

	call	sizemem
	movw	%ax, WA_EXTMEM
	ret

/*
 * Count whole megabytes of memory above the 16 MiB line, and return the
 * total in AX.  Real mode cannot reach that far, so briefly enter protected
 * mode to give FS a 4 GiB limit and keep using it after dropping back --
 * the segment's cached limit survives, which is what makes the probe
 * possible without the repeated CPU resets the NEC firmware uses.
 *
 * A20 has to be released first.  While it is masked every odd megabyte
 * aliases onto the even one below it, so the probe would read its own
 * signature back forever and never find the end of memory.  The line is put
 * back the way it was found, since the BIOS drives it itself later.
 */
sizemem:
	pushl	%ebx
	push	%cx
	push	%si
	push	%di
	push	%dx

	inb	$A20_CMD, %al		/* bit 0 set means A20 is masked */
	andb	$0x01, %al
	movb	%al, %dh
	movb	$0x02, %al		/* release it for the probe */
	outb	%al, $A20_CMD

	/*
	 * Keep the live descriptor table in ordinary low RAM.  KVM maps the
	 * banked firmware window for instruction fetches, but descriptor-table
	 * walks cannot reliably use a table inside that changing ROM alias.
	 * The NEC firmware likewise constructs its protected-mode GDT in RAM.
	 */
	push	%ds
	push	%es
	push	%cs
	pop	%ds
	xorw	%ax, %ax
	movw	%ax, %es
	movw	$gdt, %si
	movw	$GDT_RAM, %di
	movw	$(gdt_end - gdt), %cx
	rep movsb
	pop	%es
	pop	%ds

	cli
	lgdt	%cs:gdt_ram_desc
	movl	%cr0, %eax
	orb	$1, %al
	movl	%eax, %cr0
	/*
	 * KVM requires an architecturally complete protected-mode transition:
	 * reload CS before loading a protected-mode data selector.  TCG also
	 * accepted the shorter sequence which left the real-mode CS cache live,
	 * but real hardware does not guarantee it.
	 */
	ljmpl	$GDT_CODE16, $(sizemem_pm_enter + ROM_WINDOW_BASE)
sizemem_pm_enter:
	movw	$GDT_FLAT_DS, %bx
	movw	%bx, %fs
	andb	$~1, %al
	movl	%eax, %cr0
	ljmp	$0xf800, $sizemem_unreal
sizemem_unreal:

	xorw	%si, %si		/* megabytes found */
	movl	$0x01000000, %ebx	/* first address above 16 MiB */
1:
	movl	%fs:(%ebx), %edx	/* remember, restore before leaving */
	movl	$MEM_PROBE_SIG, %fs:(%ebx)
	cmpl	$MEM_PROBE_SIG, %fs:(%ebx)
	jne	2f
	movl	%edx, %fs:(%ebx)
	incw	%si
	addl	$0x00100000, %ebx
	cmpw	$MEM_PROBE_MAX, %si
	jb	1b
2:
	/*
	 * Do not leak the flat FS descriptor into the main BIOS and IPL.
	 *
	 * Merely loading FS=0 after returning to real mode is not sufficient
	 * on every CPU/emulator: the selector changes, while the hidden
	 * descriptor cache can retain its 4-GiB limit ("unreal mode").  DOS
	 * relies on ordinary 64-KiB segment wrapping during early processor
	 * and memory detection.  Reload FS from an explicit 16-bit descriptor
	 * while PE is set, then return to real mode and change only its visible
	 * selector to zero.
	 */
	movl	%cr0, %eax
	orb	$1, %al
	movl	%eax, %cr0
	ljmpl	$GDT_CODE16, $(sizemem_pm_restore + ROM_WINDOW_BASE)
sizemem_pm_restore:
	movw	$GDT_REAL_DS, %bx
	movw	%bx, %fs
	andb	$~1, %al
	movl	%eax, %cr0
	ljmp	$0xf800, $sizemem_real
sizemem_real:
	xorw	%bx, %bx
	movw	%bx, %fs

	testb	%dh, %dh		/* restore the A20 mask if it was on */
	jz	3f
	movb	$0x03, %al
	outb	%al, $A20_CMD
3:
	movw	%si, %ax
	pop	%dx
	pop	%di
	pop	%si
	pop	%cx
	popl	%ebx
	ret

	.align	8
gdt:
	.quad	0			/* null */
	.word	0xffff, 0x0000		/* flat data: base 0, limit 4 GiB */
	.byte	0x00, 0x92, 0xcf, 0x00
	.word	0xffff, 0x0000		/* real-mode data: base 0, limit 64 KiB */
	.byte	0x00, 0x92, 0x00, 0x00
	.word	0xffff, 0x0000		/* flat 16-bit code, 4 GiB limit */
	.byte	0x00, 0x9a, 0x8f, 0x00
gdt_end:

gdt_ram_desc:
	.word	gdt_end - gdt - 1
	.long	GDT_RAM

/*
 * Bring both 8259 interrupt controllers up.  The main BIOS assumes this has
 * already happened: it enables individual sources by writing the mask
 * register directly (in al,0x02 / out 0x02,al) and never issues an ICW
 * sequence of its own.  In particular it arms the CRT vertical retrace
 * interrupt and then spins until the handler fires, so a machine whose PIC
 * was never initialised hangs there with a blank screen.
 *
 * Vector bases are the PC-98 architectural ones, 0x08 for the master and
 * 0x10 for the slave, cascaded on the master's IR7.
 */
pic_init:
	movb	$0x11, %al		/* ICW1: cascade, edge, ICW4 follows */
	outb	%al, $PIC1_CMD
	movb	$0x08, %al		/* ICW2: vector base */
	outb	%al, $PIC1_DATA
	movb	$0x80, %al		/* ICW3: slave attached to IR7 */
	outb	%al, $PIC1_DATA
	movb	$0x1d, %al		/* ICW4: 8086 mode, buffered master */
	outb	%al, $PIC1_DATA

	movb	$0x11, %al
	outb	%al, $PIC2_CMD
	movb	$0x10, %al		/* ICW2: vector base */
	outb	%al, $PIC2_DATA
	movb	$0x07, %al		/* ICW3: cascade identity 7 */
	outb	%al, $PIC2_DATA
	movb	$0x09, %al		/* ICW4: 8086 mode, buffered slave */
	outb	%al, $PIC2_DATA

	/*
	 * Mask every source, but leave the cascade open.  Devices on the slave
	 * reach the CPU only through the master's IR7, and code that enables
	 * one of them -- the disk BIOS unmasks IRQ9 and waits for the drive to
	 * interrupt -- touches only the slave's own mask register.  Masking
	 * IR7 here would make those interrupts disappear.
	 */
	movb	$0x7f, %al
	outb	%al, $PIC1_DATA
	movb	$0xff, %al
	outb	%al, $PIC2_DATA
	ret

/*
 * Program the chipset through PCI configuration space.
 *
 * The main BIOS does not set these up; it reads them back and waits on them.
 * In particular it polls the C-bus bridge's register 0x64 and never leaves
 * that loop unless the value below is already in place, which is why a
 * machine whose ITF skipped this stalls with a blank screen right after the
 * PCI enumeration.  The values are the ones the Xa7 firmware writes, in
 * its order -- several registers are written more than once on purpose, so
 * this is a replayed sequence rather than a set of final values.
 *
 * DS must already address this ROM.
 */
pci_init:
	movw	$pci_table, %si
1:
	cmpw	$pci_table_end, %si
	jae	2f
	movw	$PCI_CONF_ADDR, %dx
	lodsl
	outl	%eax, %dx
	movw	$PCI_CONF_DATA, %dx
	lodsl
	outl	%eax, %dx
	jmp	1b
2:
	ret

pci_table:
	/* host bridge / memory controller (device 0) */
	.long	0x80000054, 0x00000000
	.long	0x80000004, 0xf5000106
	.long	0x80000054, 0x00000330
	.long	0x80000058, 0x00000001
	.long	0x8000005c, 0x4004a511
	.long	0x80000060, 0x000c000a
	.long	0x80000064, 0x00000000
	.long	0x80000068, 0x00000000
	.long	0x8000006c, 0x0000aaaa
	.long	0x80000070, 0x0000000a
	.long	0x80000074, 0x00b10000
	.long	0x80000078, 0x00010000
	.long	0x8000007c, 0x0000b000
	/* C-bus bridge (device 6) */
	.long	0x80003004, 0x3a00010f
	.long	0x80003040, 0x00ef0010
	.long	0x80003044, 0xfffbfffa
	.long	0x80003048, 0xfffefffe
	.long	0x8000304c, 0x0000ffff
	.long	0x80003060, 0x80808080
	.long	0x80003064, 0x18073f10
	.long	0x80003068, 0x0d000132
	.long	0x8000306c, 0x00000000
	/* device 7 */
	.long	0x80003804, 0x02800143
	.long	0x80003840, 0x00000000
	.long	0x80003844, 0x00000001
	/* interrupt routing, walked in three steps per register */
	.long	0x80003050, 0x80828180
	.long	0x80003050, 0x8f828180
	.long	0x80003050, 0x0f020100
	.long	0x80003054, 0x80808080
	.long	0x80003054, 0x87868584
	.long	0x80003054, 0x07860504
	.long	0x80003058, 0x8b8a8980
	.long	0x80003058, 0x8b8a8988
	.long	0x80003058, 0x0b0a0908
	.long	0x8000305c, 0x80808d80
	.long	0x8000305c, 0x8f8e8d8c
	.long	0x8000305c, 0x8f0e0d8c
	.long	0x80003054, 0x07868504
	/* open a window for the option-ROM probe, then close it again */
	.long	0x80000074, 0x00b10001
	.long	0x80000078, 0x00010003
	.long	0x80003064, 0x18053f10
	.long	0x80004010, 0x20000000
	.long	0x80004014, 0x00080000
	.long	0x80004004, 0xffffffff
	.long	0x80004004, 0xfffffffc
	.long	0x80000074, 0x00b10000
	.long	0x80000078, 0x00010000
	.long	0x80003064, 0x18073f10
	.long	0x80000054, 0x00000330
	/*
	 * Optional QEMU USB controllers.  Writes to absent devices are ignored.
	 * UHCI (00:08.0) uses I/O 6000h; EHCI (00:0d.0) uses MMIO F1000000h.
	 * F0000000h is reserved for the Core-Graph linear framebuffer.
	 * Both share the fixed PCI interrupt route, IRQ 14.
	 */
	.long	0x80004020, 0x00006001
	.long	0x80004004, 0x00000005
	.long	0x8000403c, 0x0000000e
	.long	0x80006810, 0xf1000000
	.long	0x80006804, 0x00000006
	.long	0x8000683c, 0x0000000e
pci_table_end:

/*
 * Bring the display controllers up.
 *
 * The BIOS assumes the firmware has already put the GDCs and the mode
 * registers into a sane state; it programs the cursor and writes characters
 * but never performs this initial sequence itself.  Without it the screen
 * body never scans out, however much of the rest is enabled.
 *
 * DS must already address this ROM.
 */
disp_init:
	movw	$disp_table, %si
1:
	cmpw	$disp_table_end, %si
	jae	2f
	lodsw
	movw	%ax, %dx
	lodsb
	outb	%al, %dx
	outb	%al, $WAIT_IO
	jmp	1b
2:
	ret

#include "disp.inc"

/*
 * Load the analog palette.
 *
 * Nothing else programs it, and an all-zero palette paints every colour
 * black: the screen looks dead even though the text plane holds the right
 * characters and the controllers are running.
 *
 * DS must already address this ROM.
 */
pal_init:
	movw	$pal_table, %si
1:
	cmpw	$pal_table_end, %si
	jae	2f
	lodsb
	outb	%al, $PAL_INDEX
	lodsb
	outb	%al, $PAL_GREEN
	lodsb
	outb	%al, $PAL_RED
	lodsb
	outb	%al, $PAL_BLUE
	jmp	1b
2:
	ret

	/* entry, green, red, blue -- the standard PC-98 sixteen colours */
pal_table:
	.byte	0x0, 0x0, 0x0, 0x0
	.byte	0x1, 0x0, 0x0, 0x7
	.byte	0x2, 0x0, 0x7, 0x0
	.byte	0x3, 0x0, 0x7, 0x7
	.byte	0x4, 0x7, 0x0, 0x0
	.byte	0x5, 0x7, 0x0, 0x7
	.byte	0x6, 0x7, 0x7, 0x0
	.byte	0x7, 0x7, 0x7, 0x7
	.byte	0x8, 0x4, 0x4, 0x4
	.byte	0x9, 0x0, 0x0, 0xf
	.byte	0xa, 0x0, 0xf, 0x0
	.byte	0xb, 0x0, 0xf, 0xf
	.byte	0xc, 0xf, 0x0, 0x0
	.byte	0xd, 0xf, 0x0, 0xf
	.byte	0xe, 0xf, 0xf, 0x0
	.byte	0xf, 0xf, 0xf, 0xf
pal_table_end:

/*
 * Start the interval timer.
 *
 * Left unprogrammed the 8253 free-runs from whatever state it powered up in,
 * and the BIOS's delay loops then finish at unpredictable points -- the same
 * image boots to different places from one run to the next.  The NEC
 * firmware's sequence is replayed verbatim because the counters are loaded
 * as command/count streams through the same ports.
 *
 * DS must already address this ROM.
 */
pit_init:
	movw	$pit_table, %si
1:
	cmpw	$pit_table_end, %si
	jae	2f
	lodsw
	movw	%ax, %dx
	lodsb
	outb	%al, %dx
	jmp	1b
2:
	ret

#include "pit.inc"

/*
 * Publish the IDE probe bitmap.
 *
 * The disk BIOS looks for a one-byte latch at 0xF8E90, which overlays the
 * banked BIOS window and is only writable while host-bridge config byte 0x69
 * bit 4 is set.  The firmware puts its candidate-drive mask there; the
 * chipset narrows the low nibble to the slots that are actually populated.
 * Without it the disk BIOS keeps probing channels that are not there, and
 * the main BIOS never enables the D000 shadow it needs for the disk option
 * ROM.
 *
 * DS must already address this ROM, which is also the window the latch
 * appears in.
 */
ide_probe_latch:
	movl	$PCI_HOST_REG68, %eax
	movw	$PCI_CONF_ADDR, %dx
	outl	%eax, %dx
	movw	$PCI_CONF_DATA, %dx
	inl	%dx, %eax
	pushl	%eax			/* remember, the gate must not stay open */
	orl	$PCI_BIOS_PROBE_GATE, %eax
	outl	%eax, %dx

	movb	$IDE_PROBE_MASK, F8E90_OFFSET

	popl	%eax
	outl	%eax, %dx
	ret

/*
 * Seed the memory switches.
 *
 * A PC-98 keeps its configuration -- the "memory switches" -- not in NVRAM
 * but inside the character generator's user-definable area, reached through
 * the CG window ports.  Only codes 0x56xx are writable there
 * (cgwindow_pattern_write enforces it), and the byte at code 0x5610 line
 * 0x20 is the marker the BIOS tests: it reads 0x5A to mean "the switches are
 * valid".  Without them the BIOS derives a different memory configuration,
 * programs the host bridge accordingly, and stalls.
 *
 * DS must already address this ROM.
 */
memsw_init:
	movb	$0x56, %al		/* CG code high, fixed for this area */
	outb	%al, $CG_CODE_HI
	movw	$memsw_table, %si
1:
	cmpw	$memsw_table_end, %si
	jae	2f
	lodsb
	outb	%al, $CG_CODE_LO
	lodsb
	outb	%al, $CG_LINE
	lodsb
	outb	%al, $CG_PATTERN
	jmp	1b
2:
	ret

#include "memsw.inc"

/*
 * Load the software DIP switches.
 *
 * These hold the same configuration as the memory switches but live in their
 * own device, and the BIOS reads them directly.  Access is gated by the
 * control register at 0x8F1F: 0x80 opens the bank for writing, 0xC0 latches
 * it again.  The data ports are 0x841E..0x8F1E, one byte each, addressed by
 * the high byte of the port number.
 *
 * DS must already address this ROM.
 */
sdip_init:
	movb	$0x80, %al		/* unlock */
	movw	$SDIP_CTRL, %dx
	outb	%al, %dx

	movw	$sdip_table, %si
1:
	cmpw	$sdip_table_end, %si
	jae	2f
	lodsb				/* port high byte */
	movb	%al, %dh
	movb	$0x1e, %dl
	lodsb
	outb	%al, %dx
	jmp	1b
2:
	movb	$0xc0, %al		/* latch */
	movw	$SDIP_CTRL, %dx
	outb	%al, %dx
	ret


/*
 * Reproduce the rest of the work area the NEC firmware leaves behind.
 *
 * Several cells here are results the BIOS consumes rather than settings it
 * recomputes -- notably it decides whether to shadow the D000 segment from
 * them.  The list was obtained by halting both firmwares at the main BIOS
 * entry and diffing low RAM, so it is exactly the state we were missing;
 * it runs last so it wins over the earlier, coarser initialisation.
 *
 * DS must address this ROM.
 */
wa_seed:
	xorw	%ax, %ax
	movw	%ax, %es
	movw	$wa_seed_table, %si
1:
	cmpw	$wa_seed_table_end, %si
	jae	2f
	lodsw
	movw	%ax, %di
	lodsb
	movb	%al, %es:(%di)
	jmp	1b
2:
	ret

#include "waseed.inc"

	/*
	 * Text GDC parameter RAM: four (start address, length) partitions,
	 * as programmed by the NEC firmware for the 80x25 text screen.
	 */
gdc_pram:
	.byte	0x00, 0x00, 0xf0, 0x3f
	.byte	0x00, 0x00, 0x10, 0x00
	.byte	0x00, 0x00, 0x10, 0x00
	.byte	0x00, 0x00, 0x10, 0x04
gdc_pram_end:

	/* port high byte, value */
sdip_table:
	.byte	0x84, 0x8f
	.byte	0x85, 0x80
	.byte	0x86, 0x80
	.byte	0x87, 0x80
	.byte	0x88, 0x80
	.byte	0x89, 0x80
	.byte	0x8a, 0x80
	.byte	0x8b, 0x80
	.byte	0x8c, 0x80
	.byte	0x8d, 0x80
	.byte	0x8e, 0x49
	.byte	0x8f, 0x98
sdip_table_end:

	/*
	 * Runs from RAM at TRAMPOLINE, not from this address, with AL and DX
	 * already loaded by the caller.  Keeping it to these two instructions
	 * matters: at 0x04F8 anything longer would run into the work-area
	 * cells at 0x0500, and the disk BIOS jumps here the same way, so the
	 * calling convention has to stay the NEC one.
	 *
	 * FD80:0002 is the main BIOS entry taken once the ITF has finished.
	 * It is deliberately not FD80:0000, the address behind the CPU reset
	 * vector: that one is the cold-start path which expects to run before
	 * any firmware has, and re-entering it here restarts the machine.
	 * Offset 2 is the post-ITF entry, and is where the NEC ITF's own
	 * 0000:04F8 stub jumps.
	 */
bankflip_stub:
	outb	%al, %dx
	ljmp	$0xfd80, $0x0002
bankflip_stub_end:

	/*
	 * CPU reset vector.  0xFFFF0 maps here while the ITF bank is selected.
	 */
	.org	RESET_VECTOR
	.globl	reset_vector
reset_vector:
	ljmp	$0xf800, $ITF_ENTRY

	.org	BANK_SIZE
