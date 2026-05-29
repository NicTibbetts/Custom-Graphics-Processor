; gfx16_cpu_test_program.asm: a small test program for the GFX16 CPU.
; it checks the basic instruction paths for control flow, load/store, and jump instructions.

.data
; keep one scratch word in normal data memory so load/store can be tested
; without colliding with the memory mapped io range.
scratch: .word 0

.text
; this tiny program checks the core instruction paths without the full graphics
; demo around it. success and failure both report through leds so the testbench
; can react immediately.
main:
    LDI r0, 2
    LDI r1, 3
    BEQ r0, r1, fail_beq_not_taken

    LDI r2, 9
    BEQ r2, r2, beq_taken
    JMP fail_beq_taken

beq_taken:
    BLT r1, r0, fail_blt_not_taken
    BLT r0, r1, blt_taken
    JMP fail_blt_taken

blt_taken:
    LDI r3, 85
    LDI r6, scratch
    STORE r6, r3
    LOAD r4, r6
    BEQ r4, r3, jump_test
    JMP fail_load

jump_test:
    JMP success
    LDI r5, 1

; if control flow, store/load, and jump all worked, finish with one clr and plot.
success:
    LDI r7, 15
    LDI r6, 244
    STORE r6, r3
    CLR
    LDI r0, 10
    LDI r1, 12
    PLOT r0, r1

done:
    JMP done

fail_beq_not_taken:
    LDI r3, 17
    JMP fail_write

fail_beq_taken:
    LDI r3, 18
    JMP fail_write

fail_blt_not_taken:
    LDI r3, 19
    JMP fail_write

fail_blt_taken:
    LDI r3, 20
    JMP fail_write

fail_load:
    LDI r3, 21

; every failure path writes a distinct led code so the testbench can identify
; which instruction family broke.
fail_write:
    LDI r6, 244
    STORE r6, r3

fail_loop:
    JMP fail_loop