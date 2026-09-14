/*
 * QEMU NEC PC-9821 keyboard (8251-style SIO at 0x41/0x43, IRQ 1)
 *
 * PC-98 support
 *   Copyright (c) 2009 TAKEDA, toshiya
 *
 * PC-98 support modernisation
 *   Copyright (c) 2026 Awe Morris
 *
 * This device is derived from the PC-98 model in the QEMU/9821 fork (GPL,
 * by TAKEDA toshiya) and has been reimplemented and restructured for modern
 * QEMU.  Its register-level behaviour was cross-checked against the Neko
 * Project II and NP21W emulators.  The AT-set1 to PC-98 scan-code tables
 * come from that fork.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "standard-headers/linux/input-event-codes.h"
#include "hw/core/irq.h"
#include "hw/isa/isa.h"
#include "hw/input/pc98-kbd.h"
#include "system/ioport.h"
#include "ui/input.h"
#include "migration/vmstate.h"

#define KBD_FIFO_SIZE      256

/* deliver queued bytes ~8 ms apart */
#define KBD_RX_INTERVAL_NS (8 * 1000000LL)

/* 8251 status-register bits returned on the status port (0x43 read). */
enum {
    KST_TXRDY   = 0x01,
    KST_RXRDY   = 0x02,
    KST_TXEMPTY = 0x04,
    KST_PARITY  = 0x08,
    KST_OVERRUN = 0x10,
    KST_FRAMING = 0x20,
    KST_SYNDET  = 0x40,
    KST_DSR     = 0x80,
};

/*
 * The 8251 is programmed through a short state machine on the command port:
 * after a reset it expects a mode byte, then, in synchronous mode, one or two
 * sync characters, after which it runs and further writes are command bytes.
 * Asynchronous mode skips the sync-character phases and runs immediately.
 */
enum {
    CFG_AWAIT_MODE,
    CFG_AWAIT_SYNC_FIRST,
    CFG_AWAIT_SYNC_LAST,
    CFG_RUNNING,
};

/* Lock-key state bits, reported back by the LED read command. */
enum {
    LOCK_NUM  = 0x01,
    LOCK_CAPS = 0x04,
    LOCK_KANA = 0x08,
    LOCK_ALL  = LOCK_NUM | LOCK_CAPS | LOCK_KANA,
};

/*
 * Translation from AT set-1 scan codes to PC-98 key codes.  Both code sets
 * are fixed properties of their respective keyboards, so this table is just
 * the correspondence between the same physical keys.  Entries with no PC-98
 * equivalent hold 0xff.  A second table covers the 0xE0-prefixed (extended)
 * set-1 codes: cursor keys, the right-hand modifiers and the Japanese
 * conversion keys.
 */
static const uint8_t at_set1_to_pc98[128] = {
    0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
//0 未使用,ESC,1,2,3,4,5,6,
    0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0e, 0x0f,
//8 7,8,9,0,<->,<=>,BS,TAB 5576キーボードでは=(SHIFT -)を入力すると^が出る
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
//10 q,w,e,r,t,y,u,i
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x74, 0x1d, 0x1e,
//18 o,p,<[>,<]>,ENTER,LCTRL,a,s 5576キーボードでは記号部は<]>、<\>で<[>,<]>が出る
    0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26,
//20 d,f,g,h,j,k,l,;
    0x27, 0xff, 0x70, 0x28, 0x29, 0x2a, 0x2b, 0x2c,
//28 ',`,LSHIFT,<\>,z,x,c,v
//    0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x70, 0x45,
    0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x45,//右シフトを ロ_キーに変更
//30 v,b,n,m,<,>,<.>,</>,RSHIFT,<*(pad)>
    0x73, 0x34, 0x71, 0x62, 0x63, 0x64, 0x65, 0x66,
//38 LALT,SPACE,CAPS,F1,F2,F3,F4,F5
//    0x67, 0x68, 0x69, 0x6a, 0x6b, 0xff, 0xff, 0x42,
    0x67, 0x68, 0x69, 0x6a, 0x6b, 0xff, 0x54, 0x42,//SCrollLockをvf3に変更
//40 F6,F7,F8,F9,F10,Num,ScrollLock,7(pad)
    0x43, 0x44, 0x40, 0x46, 0x47, 0x48, 0x49, 0x4a,
//48 8(pad),9(pad),<-(pad)>,4(pad),5(pad),6(pad),<+(pad)>,1(pad)
//    0x4b, 0x4c, 0x4e, 0x50, 0xff, 0xff, 0xff, 0x60,//F11はSTOP
    0x4b, 0x4c, 0x4e, 0x50, 0xff, 0xff, 0xff, 0x52,//F11はvf1に変更
//50 2(pad),3(pad),0(pad),<.(pad)>,未使用,未使用,未使用,F11
//    0x61, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,//F12はCOPY
    0x53, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,//F12はvf2に変更
//58 F12,CR(pad),RCTRL,</(pad)>,Printscreen,RALT,HOME,UP
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//60
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//68
    0xff, 0xff, 0xff, 0x33, 0xff, 0xff, 0xff, 0xff,
//70 0x73(jp106のロ_)はpc98の0x33でロ_ us101にはない
    0xff, 0x35, 0xff, 0x51, 0xff, 0x0d, 0xff, 0xff,
//78 未使用,変換(jp106),未使用,無変換(jp106),未使用,YEN記号(jp106),未使用,未使用
};

static const uint8_t at_set1_e0_to_pc98[128] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//10
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//    0xff, 0xff, 0xff, 0xff, 0x1c, 0x74, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0x1c, 0x35, 0xff, 0xff,//右CTRLをXFERに変更
//???,???,???,???,ENTER,RCTRL,???,???

//20
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,

//30
    0xff, 0xff, 0xff, 0xff, 0xff, 0x41, 0xff, 0xff,
// ???,???,???,???,???,</(pad)>,???,??? 5576keyboardの/(pad)がここにきてるっぽい
    0x72, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//RALT

//40
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3e,
//    0x3a, 0x36, 0xff, 0x3b, 0xff, 0x3c, 0xff, 0x3f,
    0x3a, 0x37, 0xff, 0x3b, 0xff, 0x3c, 0xff, 0x3f,//Rollup ->PageDown
//50
//    0x3d, 0x37, 0x38, 0x39, 0xff, 0xff, 0xff, 0xff,
    0x3d, 0x36, 0x38, 0x39, 0xff, 0xff, 0xff, 0xff,//RollDown->PageUP
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//60
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
//70
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

struct Pc98KbdState {
    ISADevice parent_obj;

    /* keyboard-side state */
    uint8_t lock_flags;
    uint8_t key_down[128];

    /* 8251 USART state */
    uint8_t cfg_phase;
    uint8_t status_reg;
    bool rts;
    bool rx_enabled;
    bool tx_enabled;
    uint8_t rx_latch;
    uint8_t fifo[KBD_FIFO_SIZE];
    int fifo_len;
    int fifo_tail;
    int fifo_head;
    uint8_t cmd_bytes[2];
    int cmd_len;

    PortioList portio_list;
    QEMUTimer *rx_timer;
    QemuInputHandlerState *input_handler;
    qemu_irq irq;
uint8_t nt_boot;
};

/* --- keyboard-to-host byte stream --- */

/*
 * Queue one byte to be handed to the host.  Delivery is paced by the receive
 * timer, started here when the FIFO transitions from empty to non-empty, so the
 * guest observes realistic inter-byte gaps rather than a burst.
 */
static void kbd_enqueue(Pc98KbdState *s, uint8_t value)
{
    if (s->fifo_len >= KBD_FIFO_SIZE) {
        return;
    }
    s->fifo[s->fifo_head++ & (KBD_FIFO_SIZE - 1)] = value;
    if (s->fifo_len++ == 0) {
        timer_mod(s->rx_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + KBD_RX_INTERVAL_NS);
    }
}

/*
 * Process a command byte the host wrote to the keyboard.  Two-byte commands
 * latch the opcode and complete on their parameter byte.  Recognised commands
 * are acknowledged with 0xfa (and, for identity queries, followed by their
 * report bytes); anything unknown is rejected with 0xfc.
 */
static void kbd_handle_command(Pc98KbdState *s, uint8_t value)
{
    s->cmd_bytes[s->cmd_len++ & 1] = value;

    switch (s->cmd_bytes[0]) {
    case 0x95:                          /* two-byte configuration commands */
    case 0x9c:
        kbd_enqueue(s, 0xfa);
        if (s->cmd_len == 2) {
            s->cmd_len = 0;
        }
        break;
    case 0x96:                          /* report keyboard identification */
        kbd_enqueue(s, 0xfa);
        kbd_enqueue(s, 0xa0);
        kbd_enqueue(s, 0x85);
        s->cmd_len = 0;
        break;
    case 0x99:
        kbd_enqueue(s, 0xfa);
        kbd_enqueue(s, 0xfb);
        s->cmd_len = 0;
        break;
    case 0x9d:                          /* get or set the lock LEDs */
        kbd_enqueue(s, 0xfa);
        if (s->cmd_len == 2) {
            if (s->cmd_bytes[1] == 0x60) {
                kbd_enqueue(s, 0x70 | (s->lock_flags & LOCK_ALL));
            } else {
                s->lock_flags = value;
            }
            s->cmd_len = 0;
        }
        break;
    case 0x9f:
        kbd_enqueue(s, 0xfa);
        kbd_enqueue(s, 0xa0);
        kbd_enqueue(s, 0x80);
        s->cmd_len = 0;
        break;
    default:
        kbd_enqueue(s, 0xfc);
        s->cmd_len = 0;
        break;
    }
}

static void pc98_kbd_event(DeviceState *dev, QemuConsole *src,
                           QemuInputEvent *evt)
{
    Pc98KbdState *s = PC98_KBD(dev);
    uint16_t set1;
    uint8_t keycode;

    assert(evt->type == INPUT_EVENT_KIND_KEY);

    /* evt->key.key is a Linux keycode; map it to an AT set-1 code first. */
    if (evt->key.key >= qemu_input_map_linux_to_atset1_len) {
        return;
    }
    set1 = qemu_input_map_linux_to_atset1[evt->key.key];
    if (set1 == 0) {
        return;
    }

    if ((set1 & 0xff00) == 0xe000) {
        keycode = at_set1_e0_to_pc98[set1 & 0x7f];
    } else if (set1 < 0x80) {
        keycode = at_set1_to_pc98[set1 & 0x7f];
    } else {
        return;
    }
    if (keycode == 0xff) {
        return;
    }

    if (!evt->key.down) {
        if (s->key_down[keycode]) {
            kbd_enqueue(s, keycode | 0x80);         /* break code */
        }
        s->key_down[keycode] = 0;
        return;
    }

    /*
     * CAPS and KANA are locking keys: the physical keyboard toggles them and
     * reports the resulting make or break, rather than a plain make on every
     * press.  All other keys report a make (preceded by a synthetic break if
     * the guest somehow still holds them, guarding against a lost release).
     */
    if (keycode == 0x71) {
        s->lock_flags ^= LOCK_CAPS;
        kbd_enqueue(s, (s->lock_flags & LOCK_CAPS) ? 0x71 : (0x71 | 0x80));
    } else if (keycode == 0x72) {
        s->lock_flags ^= LOCK_KANA;
        kbd_enqueue(s, (s->lock_flags & LOCK_KANA) ? 0x72 : (0x72 | 0x80));
    } else {
        if (s->key_down[keycode]) {
            kbd_enqueue(s, keycode | 0x80);
        }
        kbd_enqueue(s, keycode);
        s->key_down[keycode] = 1;
    }
}

/*
 * SDL keycodes below 0x80 are the unmodified character printed on the host
 * key.  Translate those symbols to the corresponding keys on the PC-98 JIS
 * layout instead of blindly treating a US keyboard as though its physical
 * punctuation keys had JIS legends.  The Linux keycodes returned here are
 * deliberately fed through the normal AT-set1-to-PC-98 path above, keeping a
 * single implementation of make/break and lock-key handling.
 *
 * This correspondence follows the SDL keyboard map used by NP21/W.  Symbols
 * with no direct PC-98 key retain the physical-key fallback.
 */
static unsigned int pc98_kbd_keycode_from_keysym(DeviceState *dev,
                                                  uint32_t keysym,
                                                  unsigned int keycode)
{
    static const uint16_t pc98_symbol_to_linux[128] = {
        [' ']  = KEY_SPACE,
        ['0']  = KEY_0,
        ['1']  = KEY_1,
        ['2']  = KEY_2,
        ['3']  = KEY_3,
        ['4']  = KEY_4,
        ['5']  = KEY_5,
        ['6']  = KEY_6,
        ['7']  = KEY_7,
        ['8']  = KEY_8,
        ['9']  = KEY_9,
        ['-']  = KEY_MINUS,
        ['=']  = KEY_EQUAL,
        ['^']  = KEY_EQUAL,
        ['\\'] = KEY_YEN,
        ['q']  = KEY_Q,
        ['w']  = KEY_W,
        ['e']  = KEY_E,
        ['r']  = KEY_R,
        ['t']  = KEY_T,
        ['y']  = KEY_Y,
        ['u']  = KEY_U,
        ['i']  = KEY_I,
        ['o']  = KEY_O,
        ['p']  = KEY_P,
        ['@']  = KEY_LEFTBRACE,
        ['[']  = KEY_RIGHTBRACE,
        ['a']  = KEY_A,
        ['s']  = KEY_S,
        ['d']  = KEY_D,
        ['f']  = KEY_F,
        ['g']  = KEY_G,
        ['h']  = KEY_H,
        ['j']  = KEY_J,
        ['k']  = KEY_K,
        ['l']  = KEY_L,
        [';']  = KEY_SEMICOLON,
        [':']  = KEY_APOSTROPHE,
        [']']  = KEY_BACKSLASH,
        ['z']  = KEY_Z,
        ['x']  = KEY_X,
        ['c']  = KEY_C,
        ['v']  = KEY_V,
        ['b']  = KEY_B,
        ['n']  = KEY_N,
        ['m']  = KEY_M,
        [',']  = KEY_COMMA,
        ['.']  = KEY_DOT,
        ['/']  = KEY_SLASH,
        ['_']  = KEY_RO,
    };
    unsigned int mapped;

    if (keysym == 0xa5) { /* Yen sign on macOS layouts */
        return KEY_YEN;
    }
    if (keysym >= ARRAY_SIZE(pc98_symbol_to_linux)) {
        return keycode;
    }
    mapped = pc98_symbol_to_linux[keysym];
    return mapped ? mapped : keycode;
}

static const QemuInputHandler pc98_kbd_handler = {
    .name  = "pc98-kbd",
    .mask  = INPUT_EVENT_MASK_KEY,
    .event = pc98_kbd_event,
    .keycode_from_keysym = pc98_kbd_keycode_from_keysym,
};

/* --- 8251 USART port interface --- */

static void pc98_kbd_data_write(void *opaque, uint32_t addr, uint32_t value)
{
    Pc98KbdState *s = opaque;
    if (s->status_reg & KST_TXRDY) {
        s->status_reg &= ~KST_TXEMPTY;
        kbd_handle_command(s, value);
    }
if(value == 0x70){
s->nt_boot =1;
//s->status_reg &= ~KST_TXRDY;このフラグを落とし続けると入力が消えるのでダメ
}
else s->nt_boot = 0;
}

static uint32_t pc98_kbd_data_read(void *opaque, uint32_t addr)
{
    Pc98KbdState *s = opaque;

    s->status_reg &= ~KST_RXRDY;
    qemu_set_irq(s->irq, 0);
    return s->rx_latch;
}

static void pc98_kbd_ctl_write(void *opaque, uint32_t addr, uint32_t value)
{
    Pc98KbdState *s = opaque;
    bool old_rts = s->rts;

    switch (s->cfg_phase) {
    case CFG_AWAIT_MODE:
        if (value & 0x03) {
            s->cfg_phase = CFG_RUNNING;             /* asynchronous mode */
        } else if (value & 0x80) {
            s->cfg_phase = CFG_AWAIT_SYNC_LAST;     /* sync, single sync char */
        } else {
            s->cfg_phase = CFG_AWAIT_SYNC_FIRST;    /* sync, two sync chars */
        }
        break;
    case CFG_AWAIT_SYNC_FIRST:
        s->cfg_phase = CFG_AWAIT_SYNC_LAST;
        break;
    case CFG_AWAIT_SYNC_LAST:
        s->cfg_phase = CFG_RUNNING;
        break;
    case CFG_RUNNING:
        if (value & 0x40) {                         /* internal reset */
            s->cfg_phase = CFG_AWAIT_MODE;
            break;
        }
        if (value & 0x10) {                         /* clear error flags */
            s->status_reg &= ~(KST_PARITY | KST_OVERRUN | KST_FRAMING);
        }
        s->rts = value & 0x20;
        s->rx_enabled = value & 0x04;
        s->tx_enabled = value & 0x01;
        break;
    }
    /*
     * A reply may have been queued while RTS held the receive line off.
     * The timer then observes RTS and stops without consuming the FIFO.
     * Restart it when the host releases RTS; otherwise that reply remains
     * stuck until some unrelated later command happens to enqueue a byte.
     */
    if (old_rts && !s->rts && s->fifo_len > 0) {
        timer_mod(s->rx_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  KBD_RX_INTERVAL_NS);
    }
}

static uint32_t pc98_kbd_status_read(void *opaque, uint32_t addr)
{
    Pc98KbdState *s = opaque;
    uint8_t value = s->status_reg | KST_DSR;

    if (s->tx_enabled) {
        s->status_reg |= KST_TXEMPTY;
    }
if(s->nt_boot & 1){
 value &= ~1;
 s->nt_boot = 0;
}
    return value;
}

/*
 * Receive pump: hand the next queued byte to the host if the line is enabled
 * and not held off by RTS.  A byte arriving while the previous one is still
 * unread raises the overrun flag.  While RTS is asserted the pump idles and is
 * restarted when RTS is released (or by a later enqueue).
 */
static void pc98_kbd_rx_tick(void *opaque)
{
    Pc98KbdState *s = opaque;
    uint8_t value;

    if (s->fifo_len == 0 || s->rts) {
        return;
    }

    value = s->fifo[s->fifo_tail++ & (KBD_FIFO_SIZE - 1)];
    s->fifo_len--;

    if (s->rx_enabled) {
        if (s->status_reg & KST_RXRDY) {
            s->status_reg |= KST_OVERRUN;
        } else {
            s->status_reg |= KST_RXRDY;
            s->rx_latch = value;
            qemu_set_irq(s->irq, 1);
        }
    }
    if (s->fifo_len > 0) {
        timer_mod(s->rx_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + KBD_RX_INTERVAL_NS);
    }
}

static const MemoryRegionPortio pc98_kbd_portio[] = {
    { 0x41, 1, 1, .read = pc98_kbd_data_read,   .write = pc98_kbd_data_write },
    { 0x43, 1, 1, .read = pc98_kbd_status_read, .write = pc98_kbd_ctl_write },
    PORTIO_END_OF_LIST(),
};

/* --- QOM device --- */

static void pc98_kbd_reset(DeviceState *dev)
{
    Pc98KbdState *s = PC98_KBD(dev);

    s->lock_flags = 0;
    memset(s->key_down, 0, sizeof(s->key_down));

    s->cfg_phase = CFG_AWAIT_MODE;
    s->status_reg = KST_TXRDY | KST_TXEMPTY | KST_DSR;
    s->rts = true;
    s->rx_enabled = false;
    s->tx_enabled = false;
    s->rx_latch = 0xff;
    s->fifo_len = 0;
    s->fifo_tail = 0;
    s->fifo_head = 0;
    s->cmd_len = 0;
    if (s->rx_timer) {
        timer_del(s->rx_timer);
    }
    qemu_set_irq(s->irq, 0);
s->nt_boot = 0;
}

static int pc98_kbd_post_load(void *opaque, int version_id)
{
    Pc98KbdState *s = opaque;

    qemu_set_irq(s->irq, !!(s->status_reg & KST_RXRDY));
    if (s->fifo_len > 0 && !s->rts && !timer_pending(s->rx_timer)) {
        timer_mod(s->rx_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  KBD_RX_INTERVAL_NS);
    }
    return 0;
}

static const VMStateDescription vmstate_pc98_kbd = {
    .name = "pc98-kbd",
    .version_id = 1,
    .minimum_version_id = 1,
    .post_load = pc98_kbd_post_load,
    .fields = (const VMStateField[]) {
        VMSTATE_UINT8(lock_flags, Pc98KbdState),
        VMSTATE_UINT8_ARRAY(key_down, Pc98KbdState, 128),
        VMSTATE_UINT8(cfg_phase, Pc98KbdState),
        VMSTATE_UINT8(status_reg, Pc98KbdState),
        VMSTATE_BOOL(rts, Pc98KbdState),
        VMSTATE_BOOL(rx_enabled, Pc98KbdState),
        VMSTATE_BOOL(tx_enabled, Pc98KbdState),
        VMSTATE_UINT8(rx_latch, Pc98KbdState),
        VMSTATE_UINT8_ARRAY(fifo, Pc98KbdState, KBD_FIFO_SIZE),
        VMSTATE_INT32(fifo_len, Pc98KbdState),
        VMSTATE_INT32(fifo_tail, Pc98KbdState),
        VMSTATE_INT32(fifo_head, Pc98KbdState),
        VMSTATE_UINT8_ARRAY(cmd_bytes, Pc98KbdState, 2),
        VMSTATE_INT32(cmd_len, Pc98KbdState),
        VMSTATE_TIMER_PTR(rx_timer, Pc98KbdState),
        VMSTATE_END_OF_LIST()
    }
};

static void pc98_kbd_realize(DeviceState *dev, Error **errp)
{
    ISADevice *isadev = ISA_DEVICE(dev);
    Pc98KbdState *s = PC98_KBD(dev);

    isa_register_portio_list(isadev, &s->portio_list, 0,
                             pc98_kbd_portio, s, "pc98-kbd");

    qdev_init_gpio_out(dev, &s->irq, 1);

    s->rx_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, pc98_kbd_rx_tick, s);
    s->input_handler = qemu_input_handler_register(dev, &pc98_kbd_handler);
}

static void pc98_kbd_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = pc98_kbd_realize;
    dc->vmsd = &vmstate_pc98_kbd;
    device_class_set_legacy_reset(dc, pc98_kbd_reset);
    /* Wired by board code (IRQ 1), not user creatable */
    dc->user_creatable = false;
}

static const TypeInfo pc98_kbd_info = {
    .name          = TYPE_PC98_KBD,
    .parent        = TYPE_ISA_DEVICE,
    .instance_size = sizeof(Pc98KbdState),
    .class_init    = pc98_kbd_class_init,
};

static void pc98_kbd_register_types(void)
{
    type_register_static(&pc98_kbd_info);
}

type_init(pc98_kbd_register_types)
