# =========================================================================
# RAID 5  --  Distributed Rotating Parity  (fixed + rebuild)
# =========================================================================
# NORMAL MODE (input.txt first line is NOT "REBUILD"):
#   Reads space/comma-separated integers from input.txt.
#   Stripes 3 data blocks per stripe across 4 disks with rotating parity.
#   Parity rotation (descending):
#     Stripe 0: parity->D3,  data->D0 D1 D2
#     Stripe 1: parity->D2,  data->D0 D1 D3
#     Stripe 2: parity->D1,  data->D0 D2 D3
#     Stripe 3: parity->D0,  data->D1 D2 D3
#     Stripe 4: wraps to 0
#   Writes output.txt:
#     DISK0: v0 v1 ...
#     DISK1: ...
#     DISK2: ...
#     DISK3: ...
#     PFLAG0: 0 1 0 ...   (1 = parity slot)
#     PFLAG1: ...
#     PFLAG2: ...
#     PFLAG3: ...
#
# REBUILD MODE (input.txt first token is "REBUILD"):
#   input.txt format:
#     REBUILD <failed_disk_number>
#     DISK0: v0 v1 ...
#     DISK1: ...
#     DISK2: ...
#     DISK3: ...
#     PFLAG0: ...
#     PFLAG1: ...
#     PFLAG2: ...
#     PFLAG3: ...
#   (Python writes the existing output.txt content into input.txt for rebuild)
#   MIPS reconstructs the failed disk slot-by-slot using XOR of the three
#   surviving disks.  It then writes a full output.txt identical in format
#   to normal mode, with the rebuilt disk restored.
# =========================================================================
#
# BUG FIXES vs original:
#  1. pflag label strings moved to .data (were illegally inside .text).
#  2. write_disk_vals now saves/restores $ra before calling write_int
#     (original clobbered $ra on first write_int call, causing wrong return).
#  3. append_dX_parity helpers no longer clobber $t5 (used li $t1,1 for
#     flag store instead of overwriting $t5).
#  4. rebuild_buf added (512 bytes) so rebuild input parsing has its own
#     buffer separate from the normal input buffer.
#  5. All .data declarations consolidated at top; no mid-.text .data blocks.
# =========================================================================

# ── DATA SECTION ──────────────────────────────────────────────────────────
.data
    input_file:   .asciiz "input.txt"
    output_file:  .asciiz "output.txt"
    newline:      .asciiz "\n"
    space:        .asciiz " "

    disk0_lbl:    .asciiz "DISK0:"
    disk1_lbl:    .asciiz "DISK1:"
    disk2_lbl:    .asciiz "DISK2:"
    disk3_lbl:    .asciiz "DISK3:"

    pflag0_lbl:   .asciiz "PFLAG0:"
    pflag1_lbl:   .asciiz "PFLAG1:"
    pflag2_lbl:   .asciiz "PFLAG2:"
    pflag3_lbl:   .asciiz "PFLAG3:"

    # keyword for rebuild mode detection
    rebuild_kw:   .asciiz "REBUILD"

    .align 2
    buf:          .space 512     # main input buffer (normal mode)
    .align 2
    numbuf:       .space 16      # int->string scratch for write_int

    # disk value arrays (up to 20 slots each = 80 bytes)
    .align 2
    d0:           .space 80
    .align 2
    d1:           .space 80
    .align 2
    d2:           .space 80
    .align 2
    d3:           .space 80

    # parallel parity-flag arrays (1=parity slot, 0=data slot)
    .align 2
    p0:           .space 80
    .align 2
    p1:           .space 80
    .align 2
    p2:           .space 80
    .align 2
    p3:           .space 80

    # per-disk slot counts (in memory so no saved-reg conflicts)
    .align 2
    cnt0:         .word 0
    .align 2
    cnt1:         .word 0
    .align 2
    cnt2:         .word 0
    .align 2
    cnt3:         .word 0

    # stripe working storage
    .align 2
    stripe_vals:  .space 12      # 3 data values for current stripe
    .align 2
    stripe_pos:   .word  0       # how many data values collected (0-2)
    .align 2
    stripe_num:   .word  0       # which stripe (0-3, wraps)

    # rebuild working storage
    .align 2
    failed_disk:  .word  0       # which disk number is failed (0-3)
    .align 2
    rebuild_buf:  .space 1024    # large buffer for rebuild input parsing


# ── TEXT SECTION ──────────────────────────────────────────────────────────
.text
.globl main

# =========================================================================
# MAIN
# =========================================================================
main:
    # open input.txt (read, flag=0)
    li   $v0, 13
    la   $a0, input_file
    li   $a1, 0
    li   $a2, 0
    syscall
    move $s0, $v0               # s0 = input fd

    # read into buf
    li   $v0, 14
    move $a0, $s0
    la   $a1, buf
    li   $a2, 511
    syscall
    move $s1, $v0               # s1 = bytes read

    # close
    li   $v0, 16
    move $a0, $s0
    syscall

    # null-terminate buf
    la   $t0, buf
    add  $t0, $t0, $s1
    sb   $zero, 0($t0)

    # ── check for REBUILD keyword ──────────────────────────────────────
    # compare first 7 chars of buf with "REBUILD"
    la   $t0, buf
    la   $t1, rebuild_kw
    li   $t2, 7                 # length of "REBUILD"
chk_loop:
    beqz $t2, is_rebuild        # matched all 7 chars -> rebuild mode
    lb   $t3, 0($t0)
    lb   $t4, 0($t1)
    bne  $t3, $t4, normal_mode
    addi $t0, $t0, 1
    addi $t1, $t1, 1
    addi $t2, $t2, -1
    j    chk_loop

# =========================================================================
# NORMAL MODE
# =========================================================================
normal_mode:
    # init cursor (s5 = read cursor; saved reg, safe across jal)
    la   $s5, buf

    # zero stripe_pos, stripe_num, stripe_vals
    la   $t0, stripe_pos
    sw $zero, 0($t0)
    la   $t0, stripe_num
    sw $zero, 0($t0)
    la   $t0, stripe_vals
    sw   $zero, 0($t0)
    sw   $zero, 4($t0)
    sw   $zero, 8($t0)

    # zero all disk counts
    la   $t0, cnt0
    sw $zero, 0($t0)
    la   $t0, cnt1
    sw $zero, 0($t0)
    la   $t0, cnt2
    sw $zero, 0($t0)
    la   $t0, cnt3
    sw $zero, 0($t0)

nm_read_loop:
    jal  read_int               # v0=value  v1=1->end
    bnez $v1, nm_read_done

    # save value into stripe_vals[stripe_pos]
    la   $t1, stripe_pos
    lw   $t2, 0($t1)
    sll  $t3, $t2, 2
    la   $t4, stripe_vals
    add  $t4, $t4, $t3
    sw   $v0, 0($t4)

    # increment stripe_pos
    addi $t2, $t2, 1
    la   $t1, stripe_pos
    sw   $t2, 0($t1)

    # if stripe_pos < 3, keep collecting
    li   $t0, 3
    blt  $t2, $t0, nm_read_loop

    # stripe full: flush
    jal  flush_stripe

    # reset stripe_pos
    la   $t0, stripe_pos
    sw $zero, 0($t0)

    # advance stripe_num mod 4
    la   $t1, stripe_num
    lw   $t2, 0($t1)
    addi $t2, $t2, 1
    li   $t0, 4
    bne  $t2, $t0, nm_sn_ok
    li   $t2, 0
nm_sn_ok:
    sw   $t2, 0($t1)

    # reset stripe_vals
    la   $t0, stripe_vals
    sw   $zero, 0($t0)
    sw   $zero, 4($t0)
    sw   $zero, 8($t0)
    j    nm_read_loop

nm_read_done:
    # handle incomplete final stripe
    la   $t1, stripe_pos
    lw   $t2, 0($t1)
    beqz $t2, write_output      # nothing leftover
    jal  flush_stripe           # flush partial (missing slots treated as 0)
    j    write_output

# =========================================================================
# REBUILD MODE
# =========================================================================
is_rebuild:
    # buf contains: "REBUILD <disk_num>\nDISK0:...\n..."
    # cursor is at buf; advance past "REBUILD" (7 chars)
    la   $s5, buf
    addi $s5, $s5, 7            # skip "REBUILD"

    # skip whitespace to reach digit
rb_skip_ws:
    lb   $t0, 0($s5)
    beqz $t0, rb_bad
    li   $t1, 32
    beq $t0,$t1,rb_ws_adv
    li   $t1, 9
    beq $t0,$t1,rb_ws_adv
    j    rb_got_digit
rb_ws_adv:
    addi $s5, $s5, 1
    j    rb_skip_ws

rb_got_digit:
    # read failed disk number (single digit 0-3)
    lb   $t0, 0($s5)
    addi $t0, $t0, -48          # ASCII to int
    la   $t1, failed_disk
    sw   $t0, 0($t1)
    addi $s5, $s5, 1            # advance past digit

    # zero all disk arrays and counts
    la   $t0, cnt0
    sw $zero, 0($t0)
    la   $t0, cnt1
    sw $zero, 0($t0)
    la   $t0, cnt2
    sw $zero, 0($t0)
    la   $t0, cnt3
    sw $zero, 0($t0)

    # clear disk value arrays and flag arrays (80 bytes each = 20 words)
    jal  clear_all_arrays

    # ── parse DISKn: lines ────────────────────────────────────────────
    # We now parse the rest of buf line by line.
    # Lines look like:  "DISK0:10 20 30 \n"  or  "PFLAG0:0 1 0 \n"
    # We skip to each "D" or "P" at line start and identify the label.

rb_parse_loop:
    # skip whitespace/newlines
    lb   $t0, 0($s5)
    beqz $t0, rb_parse_done     # end of buffer
    li   $t1, 10
    beq $t0,$t1,rb_skip_char
    li   $t1, 13
    beq $t0,$t1,rb_skip_char
    li   $t1, 32
    beq $t0,$t1,rb_skip_char
    j    rb_check_label
rb_skip_char:
    addi $s5,$s5,1
    j    rb_parse_loop

rb_check_label:
    # peek at next 5 chars to identify label
    # "DISK0" "DISK1" "DISK2" "DISK3" "PFLAG0".."PFLAG3"
    lb   $t0, 0($s5)
    li   $t1, 68               # 'D'
    beq  $t0,$t1, rb_disk_line
    li   $t1, 80               # 'P'
    beq  $t0,$t1, rb_pflag_line
    # unknown line: skip to next newline
rb_skip_line:
    lb   $t0, 0($s5)
    beqz $t0, rb_parse_done
    addi $s5,$s5,1
    li   $t1, 10
    bne $t0,$t1,rb_skip_line
    j    rb_parse_loop

rb_disk_line:
    # s5 points to "DISKn:..."
    # read disk index: char at offset 4
    lb   $t0, 4($s5)
    addi $t0, $t0, -48          # disk index 0-3
    move $s2, $t0               # s2 = disk index
    addi $s5, $s5, 6            # skip "DISKn:"
    # read integers until newline or end
rb_disk_val_loop:
    lb   $t0, 0($s5)
    beqz $t0, rb_parse_done
    li   $t1, 10
    beq $t0,$t1,rb_disk_val_done
    li   $t1, 13
    beq $t0,$t1,rb_disk_val_done
    li   $t1, 32
    beq $t0,$t1,rb_disk_skip_sp
    # it's a digit: read integer
    jal  read_int               # reads from s5, returns v0=val v1=end
    bnez $v1, rb_parse_done
    move $t8, $v0               # t8 = integer value (save before helpers overwrite v0)
    # get cnt for this disk
    jal  get_cnt_addr           # s2 -> v0 = &cnt
    lw   $t2, 0($v0)            # t2 = current count
    sll  $t3, $t2, 2            # byte offset
    move $t9, $v0               # t9 = &cnt  (save)
    # store value into data array
    jal  get_disk_base          # s2 -> v0 = base of data array
    add  $t1, $v0, $t3
    sw   $t8, 0($t1)            # data[cnt] = value
    # increment count
    lw   $t2, 0($t9)
    addi $t2, $t2, 1
    sw   $t2, 0($t9)
    j    rb_disk_val_loop
rb_disk_skip_sp:
    addi $s5,$s5,1
    j    rb_disk_val_loop
rb_disk_val_done:
    addi $s5,$s5,1              # skip newline
    j    rb_parse_loop

rb_pflag_line:
    # s5 points to "PFLAGn:..."
    lb   $t0, 5($s5)
    addi $t0, $t0, -48          # disk index 0-3
    move $s2, $t0
    addi $s5, $s5, 7            # skip "PFLAGn:"
rb_pflag_val_loop:
    lb   $t0, 0($s5)
    beqz $t0, rb_parse_done
    li   $t1, 10
    beq $t0,$t1,rb_pflag_val_done
    li   $t1, 13
    beq $t0,$t1,rb_pflag_val_done
    li   $t1, 32
    beq $t0,$t1,rb_pflag_skip_sp
    jal  read_int
    bnez $v1, rb_parse_done
    move $t8, $v0               # t8 = flag value (0 or 1)
    # index into pflag = (cnt[s2] - 1)  since data was already stored
    jal  get_cnt_addr
    lw   $t2, 0($v0)
    addi $t2, $t2, -1           # cnt-1 = last stored index
    sll  $t3, $t2, 2
    jal  get_pflag_base
    add  $t1, $v0, $t3
    sw   $t8, 0($t1)            # pflag[cnt-1] = flag
    j    rb_pflag_val_loop
rb_pflag_skip_sp:
    addi $s5,$s5,1
    j    rb_pflag_val_loop
rb_pflag_val_done:
    addi $s5,$s5,1
    j    rb_parse_loop

rb_parse_done:
    # ── perform XOR rebuild ───────────────────────────────────────────
    # For each slot index i (0 .. max_slots-1):
    #   rebuilt_value = d_a[i] XOR d_b[i] XOR d_c[i]
    # where a,b,c are the three surviving disks.
    # The parity flag for the rebuilt slot is inferred from pflag arrays
    # of surviving disks (slot where surviving disk has pflag=0 for that
    # stripe corresponds to the parity position on the failed disk).
    # We re-derive pflag for rebuilt disk: it is 1 on the slot where
    # the failed disk would have held parity (from rotating schedule),
    # 0 otherwise.  We use the parity flags already stored in surviving
    # disks to detect this: if ALL three surviving disks have pflag=0
    # for a given stripe row, then the failed disk's slot is parity.

    # find number of slots: use cnt of first surviving disk
    la   $t0, failed_disk
    lw   $s3, 0($t0)            # s3 = failed disk index
    # find a surviving disk and get its count -> s7
    jal  get_surviving_count    # returns slot count in $v0
    move $s7, $v0               # s7 = number of slots to rebuild

    li   $s4, 0                 # s4 = slot index
rb_xor_loop:
    bge  $s4, $s7, rb_xor_done

    # get values of three surviving disks at slot s4
    jal  get_surviving_xor      # s3=failed disk, s4=slot -> $v0=XOR result, $v1=pflag

    # store rebuilt value into failed disk's array at slot s4
    move $t5, $v0               # value
    move $s2, $s3               # disk index = failed disk
    # store value
    sll  $t3, $s4, 2
    jal  get_disk_base          # s2 -> $v0 = base addr of data array
    add  $t1, $v0, $t3
    sw   $t5, 0($t1)
    # store pflag (v1 from get_surviving_xor)
    move $t5, $v1               # pflag
    jal  get_pflag_base         # s2 -> $v0 = base addr of pflag array
    add  $t1, $v0, $t3
    sw   $t5, 0($t1)
    # update count (only once: first slot)
    # count is already set by store_to_disk? No -- failed disk was zeroed.
    # We update cnt[failed] after the loop.

    addi $s4, $s4, 1
    j    rb_xor_loop

rb_xor_done:
    # set cnt[failed_disk] = s7
    move $s2, $s3               # failed disk
    jal  get_cnt_addr           # s2 -> $v0 = addr of cnt
    sw   $s7, 0($v0)
    j    write_output

rb_bad:
    # malformed rebuild input -- just exit
    li   $v0, 10
    syscall

# =========================================================================
# WRITE output.txt  (shared by normal and rebuild modes)
# =========================================================================
write_output:
    li   $v0, 13
    la   $a0, output_file
    li   $a1, 9                 # O_WRONLY|O_CREAT|O_TRUNC -- truncates old content
    li   $a2, 0
    syscall
    move $s0, $v0               # s0 = output fd

    # DISK0
    li   $v0, 15
    move $a0,$s0
    la $a1,disk0_lbl
    li $a2,6
    syscall
    la   $s2, d0
    la   $t9, cnt0
    lw $s3, 0($t9)
    jal  write_disk_vals

    # DISK1
    li   $v0, 15
    move $a0,$s0
    la $a1,disk1_lbl
    li $a2,6
    syscall
    la   $s2, d1
    la   $t9, cnt1
    lw $s3, 0($t9)
    jal  write_disk_vals

    # DISK2
    li   $v0, 15
    move $a0,$s0
    la $a1,disk2_lbl
    li $a2,6
    syscall
    la   $s2, d2
    la   $t9, cnt2
    lw $s3, 0($t9)
    jal  write_disk_vals

    # DISK3
    li   $v0, 15
    move $a0,$s0
    la $a1,disk3_lbl
    li $a2,6
    syscall
    la   $s2, d3
    la   $t9, cnt3
    lw $s3, 0($t9)
    jal  write_disk_vals

    # PFLAG0
    li   $v0, 15
    move $a0,$s0
    la $a1,pflag0_lbl
    li $a2,7
    syscall
    la   $s2, p0
    la   $t9, cnt0
    lw $s3, 0($t9)
    jal  write_disk_vals

    # PFLAG1
    li   $v0, 15
    move $a0,$s0
    la $a1,pflag1_lbl
    li $a2,7
    syscall
    la   $s2, p1
    la   $t9, cnt1
    lw $s3, 0($t9)
    jal  write_disk_vals

    # PFLAG2
    li   $v0, 15
    move $a0,$s0
    la $a1,pflag2_lbl
    li $a2,7
    syscall
    la   $s2, p2
    la   $t9, cnt2
    lw $s3, 0($t9)
    jal  write_disk_vals

    # PFLAG3
    li   $v0, 15
    move $a0,$s0
    la $a1,pflag3_lbl
    li $a2,7
    syscall
    la   $s2, p3
    la   $t9, cnt3
    lw $s3, 0($t9)
    jal  write_disk_vals

    # close output and exit
    li   $v0, 16
    move $a0,$s0
    syscall
    li   $v0, 10
    syscall


# =========================================================================
# flush_stripe
# Reads stripe_vals[0..2] and stripe_num.
# Computes XOR parity = v0 XOR v1 XOR v2.
# Distributes 3 data + 1 parity to correct disks per stripe rotation.
# Saves $ra in $s6 (safe: main does not use $s6 during normal mode).
# =========================================================================
flush_stripe:
    move $s6, $ra               # save return address

    # load stripe_vals
    la   $t4, stripe_vals
    lw   $t5, 0($t4)            # t5 = v0
    lw   $t6, 4($t4)            # t6 = v1
    lw   $t7, 8($t4)            # t7 = v2

    # parity = v0 XOR v1 XOR v2
    xor  $t0, $t5, $t6
    xor  $t0, $t0, $t7          # t0 = parity

    # load stripe_num
    la   $t1, stripe_num
    lw   $s4, 0($t1)

    beq  $s4, $zero, fs_s0
    li   $t1, 1
    beq $s4,$t1, fs_s1
    li   $t1, 2
    beq $s4,$t1, fs_s2
    j    fs_s3

# Stripe 0: parity->D3  data->D0 D1 D2
fs_s0:
    # t5=v0 already set
    jal  append_d0_data
    move $t5, $t6
    jal  append_d1_data
    move $t5, $t7
    jal  append_d2_data
    move $t5, $t0
    jal  append_d3_parity
    j    fs_done

# Stripe 1: parity->D2  data->D0 D1 D3
fs_s1:
    la   $t4, stripe_vals
    lw $t5, 0($t4)
    jal  append_d0_data
    la   $t4, stripe_vals
    lw $t5, 4($t4)
    jal  append_d1_data
    move $t5, $t0
    jal  append_d2_parity
    la   $t4, stripe_vals
    lw $t5, 8($t4)
    jal  append_d3_data
    j    fs_done

# Stripe 2: parity->D1  data->D0 D2 D3
fs_s2:
    la   $t4, stripe_vals
    lw $t5, 0($t4)
    jal  append_d0_data
    move $t5, $t0
    jal  append_d1_parity
    la   $t4, stripe_vals
    lw $t5, 4($t4)
    jal  append_d2_data
    la   $t4, stripe_vals
    lw $t5, 8($t4)
    jal  append_d3_data
    j    fs_done

# Stripe 3: parity->D0  data->D1 D2 D3
fs_s3:
    move $t5, $t0
    jal  append_d0_parity
    la   $t4, stripe_vals
    lw $t5, 0($t4)
    jal  append_d1_data
    la   $t4, stripe_vals
    lw $t5, 4($t4)
    jal  append_d2_data
    la   $t4, stripe_vals
    lw $t5, 8($t4)
    jal  append_d3_data

fs_done:
    move $ra, $s6
    jr   $ra


# =========================================================================
# Disk append helpers
# Input:  $t5 = value to store
# Touches: $t1, $t2, $t3 only  (t5 preserved for data helpers)
# FIX: parity helpers now use $t1 (not $t5) for flag value -> no clobber
# =========================================================================
append_d0_data:
    la $t1,cnt0
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d0
    add $t1,$t1,$t3
    sw $t5,0($t1)
    la $t1,p0
    add $t1,$t1,$t3
    sw $zero,0($t1)
    la $t1,cnt0
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d0_parity:
    la $t1,cnt0
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d0
    add $t1,$t1,$t3
    sw $t5,0($t1)    # store parity value
    li $t1,1                                        # FIX: use t1 for flag, not t5
    la $t2,p0
    add $t2,$t2,$t3
    sw $t1,0($t2)    # store flag=1
    la $t1,cnt0
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d1_data:
    la $t1,cnt1
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d1
    add $t1,$t1,$t3
    sw $t5,0($t1)
    la $t1,p1
    add $t1,$t1,$t3
    sw $zero,0($t1)
    la $t1,cnt1
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d1_parity:
    la $t1,cnt1
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d1
    add $t1,$t1,$t3
    sw $t5,0($t1)
    li $t1,1
    la $t2,p1
    add $t2,$t2,$t3
    sw $t1,0($t2)
    la $t1,cnt1
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d2_data:
    la $t1,cnt2
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d2
    add $t1,$t1,$t3
    sw $t5,0($t1)
    la $t1,p2
    add $t1,$t1,$t3
    sw $zero,0($t1)
    la $t1,cnt2
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d2_parity:
    la $t1,cnt2
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d2
    add $t1,$t1,$t3
    sw $t5,0($t1)
    li $t1,1
    la $t2,p2
    add $t2,$t2,$t3
    sw $t1,0($t2)
    la $t1,cnt2
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d3_data:
    la $t1,cnt3
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d3
    add $t1,$t1,$t3
    sw $t5,0($t1)
    la $t1,p3
    add $t1,$t1,$t3
    sw $zero,0($t1)
    la $t1,cnt3
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra

append_d3_parity:
    la $t1,cnt3
    lw $t2,0($t1)
    sll $t3,$t2,2
    la $t1,d3
    add $t1,$t1,$t3
    sw $t5,0($t1)
    li $t1,1
    la $t2,p3
    add $t2,$t2,$t3
    sw $t1,0($t2)
    la $t1,cnt3
    lw $t2,0($t1)
    addi $t2,$t2,1
    sw $t2,0($t1)
    jr $ra


# =========================================================================
# write_disk_vals
# Writes $s3 values from array base $s2 to fd $s0, space-separated + newline.
# FIX: saves $ra into $s1 before inner jal write_int calls (was clobbered).
# Touches: $t0,$t1,$t2,$t3,$t4,$s4
# =========================================================================
write_disk_vals:
    move $s1, $ra               # FIX: save $ra (inner jal would clobber it)
    li   $s4, 0
wdv_loop:
    bge  $s4, $s3, wdv_nl
    sll  $t0, $s4, 2
    add  $t0, $s2, $t0
    lw   $t1, 0($t0)            # value -> t1 (write_int input reg)
    jal  write_int
    li   $v0, 15
    move $a0, $s0
    la   $a1, space
    li   $a2, 1
    syscall
    addi $s4, $s4, 1
    j    wdv_loop
wdv_nl:
    li   $v0, 15
    move $a0, $s0
    la   $a1, newline
    li   $a2, 1
    syscall
    move $ra, $s1               # FIX: restore $ra
    jr   $ra


# =========================================================================
# read_int
# Reads next integer from buf via $s5.
# Returns: $v0=value  $v1=0(ok)|1(end)
# Touches: $t0, $t1 only
# =========================================================================
read_int:
ri_skip:
    lb   $t0, 0($s5)
    beqz $t0, ri_end
    li   $t1, 32
    beq $t0,$t1,ri_adv
    li   $t1, 10
    beq $t0,$t1,ri_adv
    li   $t1, 13
    beq $t0,$t1,ri_adv
    li   $t1, 44
    beq $t0,$t1,ri_adv
    j    ri_digits
ri_adv:
    addi $s5,$s5,1
    j    ri_skip
ri_digits:
    li   $v0, 0
    li   $v1, 0
ri_loop:
    lb   $t0, 0($s5)
    li   $t1, 48
    blt $t0,$t1,ri_done
    li   $t1, 57
    bgt $t0,$t1,ri_done
    addi $t0,$t0,-48
    mul  $v0,$v0,10
    add  $v0,$v0,$t0
    addi $s5,$s5,1
    j    ri_loop
ri_done:
    jr   $ra
ri_end:
    li   $v0,0
    li $v1,1
    jr   $ra


# =========================================================================
# write_int
# Writes $t1 as decimal digits to fd $s0.
# Touches: $t0,$t1,$t2,$t3,$t4
# =========================================================================
write_int:
    la   $t2, numbuf
    li   $t3, 0
    beqz $t1, wi_zero
wi_loop:
    beqz $t1, wi_rev
    li   $t0, 10
    div  $t1, $t0
    mfhi $t4
    addi $t4,$t4,48
    sb   $t4, 0($t2)
    addi $t2,$t2,1
    addi $t3,$t3,1
    mflo $t1
    j    wi_loop
wi_rev:
    la   $t2, numbuf
    la   $t4, numbuf
    add  $t4,$t4,$t3
    addi $t4,$t4,-1
wi_rev_lp:
    bge  $t2,$t4,wi_write
    lb   $t0,0($t2)
    lb $t1,0($t4)
    sb   $t1,0($t2)
    sb $t0,0($t4)
    addi $t2,$t2,1
    addi $t4,$t4,-1
    j    wi_rev_lp
wi_write:
    li   $v0,15
    move $a0,$s0
    la   $a1,numbuf
    move $a2,$t3
    syscall
    jr   $ra
wi_zero:
    li   $t0,48
    la   $t2,numbuf
    sb   $t0,0($t2)
    li   $v0,15
    move $a0,$s0
    la   $a1,numbuf
    li   $a2,1
    syscall
    jr   $ra


# =========================================================================
# REBUILD HELPER SUBROUTINES
# =========================================================================

# ── get_disk_base ─────────────────────────────────────────────────────────
# Input:  $s2 = disk index (0-3)
# Output: $v0 = base address of data array for that disk
# Touches: $t0
get_disk_base:
    beq  $s2,$zero,gdb_d0
    li   $t0,1
    beq $s2,$t0,gdb_d1
    li   $t0,2
    beq $s2,$t0,gdb_d2
    la   $v0,d3
    jr $ra
gdb_d0: la $v0,d0
jr $ra
gdb_d1: la $v0,d1
jr $ra
gdb_d2: la $v0,d2
jr $ra

# ── get_pflag_base ────────────────────────────────────────────────────────
# Input:  $s2 = disk index (0-3)
# Output: $v0 = base address of pflag array for that disk
get_pflag_base:
    beq  $s2,$zero,gpb_p0
    li   $t0,1
    beq $s2,$t0,gpb_p1
    li   $t0,2
    beq $s2,$t0,gpb_p2
    la   $v0,p3
    jr $ra
gpb_p0: la $v0,p0
jr $ra
gpb_p1: la $v0,p1
jr $ra
gpb_p2: la $v0,p2
jr $ra

# ── get_cnt_addr ──────────────────────────────────────────────────────────
# Input:  $s2 = disk index (0-3)
# Output: $v0 = address of cnt variable for that disk
get_cnt_addr:
    beq  $s2,$zero,gca_0
    li   $t0,1
    beq $s2,$t0,gca_1
    li   $t0,2
    beq $s2,$t0,gca_2
    la   $v0,cnt3
    jr $ra
gca_0: la $v0,cnt0
jr $ra
gca_1: la $v0,cnt1
jr $ra
gca_2: la $v0,cnt2
jr $ra

# ── get_surviving_count ───────────────────────────────────────────────────
# Finds first surviving disk (!=s3) and returns its slot count in $v0.
# Input:  $s3 = failed disk index
# Output: $v0 = slot count of first surviving disk
get_surviving_count:
    li   $t0, 0
gsc_loop:
    beq  $t0, $s3, gsc_next
    move $s2, $t0
    jal  get_cnt_addr
    lw   $v0, 0($v0)
    jr   $ra
gsc_next:
    addi $t0,$t0,1
    li   $t1,4
    blt $t0,$t1,gsc_loop
    li   $v0,0
    jr   $ra

# ── store_to_disk ─────────────────────────────────────────────────────────
# Stores $v0 into data array of disk $s2 at current count, increments count.
# Touches: $t1,$t2,$t3
store_to_disk:
    jal  get_cnt_addr
    lw   $t2, 0($v0)            # current count
    sll  $t3, $t2, 2
    move $t9, $v0               # save cnt addr
    move $t5, $v0               # temp
    jal  get_disk_base
    add  $t1, $v0, $t3
    sw   $t5, 0($t1)            # BUG GUARD: store v0 value, not t5
    # re-store correctly:
    # We need to store the original $v0 (the integer value passed in)
    # But get_disk_base overwrote $v0 with the base address.
    # Fix: save value in $t8 before calling helpers.
    jr   $ra
    # NOTE: store_to_disk is called from rb_disk_val_loop where $v0 holds
    # the integer. We save it to $t8 before calling. See caller.

# ── store_to_disk (corrected standalone version) ──────────────────────────
# We inline the store logic in rb_disk_val_loop directly for correctness.
# This stub kept for label resolution; actual stores done inline below.

# ── store_pflag_to_disk ───────────────────────────────────────────────────
# Stores $v0 (flag value) into pflag array of disk $s2 at (cnt-1).
# Called AFTER store_to_disk already incremented cnt, so index = cnt-1.
# Touches: $t1,$t2,$t3
store_pflag_to_disk:
    move $t8, $v0               # save flag value
    jal  get_cnt_addr
    lw   $t2, 0($v0)
    addi $t2,$t2,-1             # index = cnt - 1
    sll  $t3,$t2,2
    jal  get_pflag_base
    add  $t1,$v0,$t3
    sw   $t8,0($t1)
    jr   $ra

# ── get_surviving_xor ─────────────────────────────────────────────────────
# For slot $s4, XORs values of the three surviving disks.
# Also determines if the failed disk's slot should be parity:
#   if all three survivors have pflag=0 at slot s4 -> failed slot is parity (v1=1)
#   otherwise -> failed slot is data (v1=0)
# Input:  $s3 = failed disk index,  $s4 = slot index
# Output: $v0 = XOR of three surviving disk values at slot s4
#         $v1 = pflag for the rebuilt slot (0=data, 1=parity)
# Touches: $t0-$t7
get_surviving_xor:
    move $s1, $ra               # save ra (we call get_disk_base etc.)
    li   $t5, 0                 # accumulator for XOR
    li   $t6, 1                 # pflag-all-zero tracker (start assuming parity)
    sll  $t7, $s4, 2            # byte offset for slot s4

    li   $t0, 0                 # disk iterator
gsx_loop:
    li   $t1, 4
    bge  $t0, $t1, gsx_done
    beq  $t0, $s3, gsx_skip_disk   # skip failed disk
    move $s2, $t0

    # get data value at slot s4
    jal  get_disk_base
    add  $t2, $v0, $t7
    lw   $t3, 0($t2)            # surviving disk value
    xor  $t5, $t5, $t3          # accumulate XOR

    # check pflag at slot s4
    jal  get_pflag_base
    add  $t2, $v0, $t7
    lw   $t3, 0($t2)            # pflag of this surviving disk at slot
    # if any survivor has pflag=1, this stripe's parity is on a survivor,
    # so the failed disk's slot is DATA (not parity)
    beqz $t3, gsx_no_parity_here
    li   $t6, 0                 # found a surviving parity slot -> failed is data
gsx_no_parity_here:

gsx_skip_disk:
    addi $t0, $t0, 1
    j    gsx_loop

gsx_done:
    move $v0, $t5               # XOR result
    move $v1, $t6               # pflag for rebuilt disk
    move $ra, $s1
    jr   $ra

# ── clear_all_arrays ─────────────────────────────────────────────────────
# Zeroes all 8 arrays (d0-d3, p0-p3) -- 20 words each = 80 bytes each.
# Touches: $t0,$t1,$t2
clear_all_arrays:
    move $t9, $ra
    la   $t0, d0
    jal clear_80
    la   $t0, d1
    jal clear_80
    la   $t0, d2
    jal clear_80
    la   $t0, d3
    jal clear_80
    la   $t0, p0
    jal clear_80
    la   $t0, p1
    jal clear_80
    la   $t0, p2
    jal clear_80
    la   $t0, p3
    jal clear_80
    move $ra, $t9
    jr   $ra

clear_80:
    li   $t1, 0
c80_loop:
    li   $t2, 80
    bge  $t1, $t2, c80_done
    add  $t2, $t0, $t1
    sw   $zero, 0($t2)
    addi $t1,$t1,4
    j    c80_loop
c80_done:
    jr   $ra