.syntax unified
.arm
.section .text.entry,"ax",%progbits
.global aa_selector, aa_read, aa_read_carplay, aa_after_set
/* aa_bt_continue, aa_gem_finish and aa_gain_getter are native addresses of
 * the supported audiomgr build, defined by the linker script per build.
 */
/* Reached from the native Bluetooth input-gain decoder (key in r7, value in
 * r0). GEM key 84 selects Android Auto music (connection 156), key 85 Apple
 * CarPlay music (connection 162). Every other key keeps the Bluetooth path.
 */
aa_selector:
    cmp r7, #84
    beq aa_selected
    cmp r7, #85
    movne r2, #21
    bne aa_bt_continue
aa_selected:
    cmp r0, #13
    bgt aa_reject
    cmn r0, #13
    blt aa_reject
    /* Preserve original handler registers and 8-byte stack alignment. */
    push {r0, r1, r4, lr}
    mov r1, r0
    sub r0, r7, #84
    bl aa_save_gain
    cmp r0, #0
    pop {r0, r1, r4, lr}
    bne aa_reject
    cmp r7, #84
    moveq r2, #156
    movne r2, #162
    b aa_bt_continue
aa_reject:
    mov r3, #8
    b aa_gem_finish
aa_read:
    mov r2, #156
    b aa_gain_getter
aa_read_carplay:
    mov r2, #162
    b aa_gain_getter
aa_after_set:
    cmp r7, #84
    beq aa_release
    cmp r7, #85
    bne aa_ack
aa_release:
    push {r0, r1, r4, lr}
    bl aa_release_lock
    cmp r0, #0
    pop {r0, r1, r4, lr}
    bne aa_reject
aa_ack:
    mov r3, #0
    b aa_gem_finish
.section .note.GNU-stack,"",%progbits
