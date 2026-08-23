/*
 * Minimal PC98 BIOS
 * Copyright (C) 2026 Awe Morris
 *
 * Interval timer setup, replayed from the stock Xa7 ITF in its
 * original order: the 8253 takes command/count streams where the same
 * port carries different meanings, so only the sequence is meaningful.
 * Format: port, value.
 */
pit_table:
	.word	0x0077
	.byte	0x76
	.word	0x0073
	.byte	0xcd
	.word	0x0073
	.byte	0x04
	.word	0x0077
	.byte	0xb6
	.word	0x0077
	.byte	0x70
	.word	0x0073
	.byte	0x00
	.word	0x0073
	.byte	0x00
	.word	0x0077
	.byte	0x30
	.word	0x0071
	.byte	0x00
	.word	0x0071
	.byte	0x00
	.word	0x0077
	.byte	0x76
	.word	0x0073
	.byte	0xcd
	.word	0x0073
	.byte	0x04
	.word	0x0077
	.byte	0xb6
	.word	0x0077
	.byte	0x76
	.word	0x0073
	.byte	0x9a
	.word	0x0073
	.byte	0x09
	.word	0x0077
	.byte	0x76
	.word	0x0073
	.byte	0xcd
	.word	0x0073
	.byte	0x04
pit_table_end:
