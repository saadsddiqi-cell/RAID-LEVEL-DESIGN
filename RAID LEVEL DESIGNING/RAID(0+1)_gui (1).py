import tkinter as tk
from tkinter import messagebox
import subprocess, os, time, re

# ── CONFIG ────────────────────────────────────────────────────────────────
MARS_JAR    = r"C:\Users\shahi\Documents\COA_LABS-4thsem\RAID LEVEL DESIGNING\RAID LEVEL DESIGNING\Mars45.jar"
INPUT_FILE  = "input.txt"
OUTPUT_FILE = "output.txt"
MAX_BLOCKS  = 12

# ── COLOURS ───────────────────────────────────────────────────────────────
BG       = "#1a1a2e"
FG       = "#e0e0e0"
TITLE    = "#a78bfa"
STATUS   = "#16213e"

P_TOP    = "#4a6fa5";  P_BODY   = "#2d4a7a";  P_RIM   = "#1a3055"   # data
M_TOP    = "#6b6b8a";  M_BODY   = "#4a4a6a";  M_RIM   = "#2d2d4a"   # mirror
F_TOP    = "#c0392b";  F_BODY   = "#922b21";  F_RIM   = "#641e16"   # failed
R_TOP    = "#16a34a";  R_BODY   = "#166534";  R_RIM   = "#14532d"   # rebuilt
PAR_TOP  = "#b45309";  PAR_BODY = "#92400e";  PAR_RIM  = "#78350f"  # RAID3 parity amber
PAR5_TOP = "#6d28d9";  PAR5_BODY= "#4c1d95";  PAR5_RIM = "#3b0764"  # RAID5 parity violet


class RAIDSim:
    def __init__(self, root):
        self.root  = root
        self.root.title("RAID Simulator")
        self.root.configure(bg=BG)
        self.root.geometry("1200x860")
        self.root.resizable(True, True)

        self.disks    = [[], [], [], []]   # values per disk
        self.pflags   = [[], [], [], []]   # RAID5 parity flags per slot (1=parity)
        self.failed   = [False] * 4
        self.rebuilt  = [False] * 4        # which disk was just rebuilt
        self._build()

    # ── UI ────────────────────────────────────────────────────────────────
    def _build(self):
        tk.Label(self.root, text="RAID SIMULATOR",
                 font=("Courier New", 22, "bold"),
                 bg=BG, fg=TITLE).pack(pady=(14, 4))

        # RAID level selector
        rf = tk.Frame(self.root, bg=BG)
        rf.pack()
        tk.Label(rf, text="RAID Level:", font=("Courier New", 11),
                 bg=BG, fg=FG).pack(side=tk.LEFT, padx=6)

        self.raid = tk.StringVar(value="RAID 0")
        levels = [
            ("RAID 0",   "#60a5fa"),
            ("RAID 0+1", "#86efac"),
            ("RAID 3",   "#fbbf24"),
            ("RAID 5",   "#c084fc"),
        ]
        for txt, col in levels:
            tk.Radiobutton(rf, text=txt, variable=self.raid, value=txt,
                           font=("Courier New", 11, "bold"),
                           bg=BG, fg=col, selectcolor="#2d2d44",
                           activebackground=BG,
                           command=self._on_level_change).pack(side=tk.LEFT, padx=14)

        # dynamic hint bar
        self.hint_var  = tk.StringVar(value="")
        self.hint_col  = "#60a5fa"
        self.hint_lbl  = tk.Label(self.root, textvariable=self.hint_var,
                                  font=("Courier New", 9, "italic"),
                                  bg=BG, fg=self.hint_col)
        self.hint_lbl.pack()

        # input row
        inf = tk.Frame(self.root, bg=BG)
        inf.pack(pady=6)
        tk.Label(inf, text="Blocks (comma separated):",
                 font=("Courier New", 11), bg=BG, fg=FG).pack(side=tk.LEFT, padx=6)
        self.entry = tk.Entry(inf, font=("Courier New", 12), width=40,
                              bg="#0f3460", fg="#e0e0e0",
                              insertbackground="#e0e0e0",
                              relief=tk.FLAT, bd=5)
        self.entry.pack(side=tk.LEFT, padx=6)
        self.entry.insert(0, "10, 20, 30, 40")

        # buttons row 1
        bf = tk.Frame(self.root, bg=BG)
        bf.pack(pady=4)
        for txt, fn, col in [
            ("Write & Run MIPS", self._run,    "#3b82f6"),
            ("Disk Failure",     self._fail,   "#ef4444"),
            ("Disk Status",      self._status, "#f59e0b"),
            ("Reset",            self._reset,  "#6b7280"),
        ]:
            tk.Button(bf, text=txt, font=("Courier New", 10, "bold"),
                      bg=col, fg="white", relief=tk.FLAT,
                      padx=12, pady=6, cursor="hand2",
                      command=fn).pack(side=tk.LEFT, padx=4)

        # buttons row 2 — Rebuild (RAID 5 only)
        bf2 = tk.Frame(self.root, bg=BG)
        bf2.pack(pady=2)
        self.rebuild_btn = tk.Button(
            bf2, text="⟳  Rebuild Failed Disk (RAID 5)",
            font=("Courier New", 10, "bold"),
            bg="#16a34a", fg="white", relief=tk.FLAT,
            padx=14, pady=6, cursor="hand2",
            command=self._rebuild,
            state=tk.DISABLED)
        self.rebuild_btn.pack()

        # canvas + scrollbar
        cf = tk.Frame(self.root, bg=BG)
        cf.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)
        self.canvas = tk.Canvas(cf, bg=BG, highlightthickness=0)
        sb = tk.Scrollbar(cf, orient=tk.VERTICAL, command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        # status bar
        self.sv = tk.StringVar(value="Ready — enter comma-separated block values.")
        tk.Label(self.root, textvariable=self.sv,
                 font=("Courier New", 10), bg=STATUS, fg=FG,
                 anchor=tk.W, padx=12, pady=4).pack(fill=tk.X, side=tk.BOTTOM)

    # ── LEVEL CHANGE ──────────────────────────────────────────────────────
    _HINTS = {
        "RAID 0":   ("", "#60a5fa", "10, 20, 30, 40"),
        "RAID 0+1": ("", "#86efac", "10, 20, 30, 40"),
        "RAID 3": (
            "RAID 3: 3 data disks + 1 dedicated parity disk  |  "
            "multiples of 3 recommended  |  parity = XOR computed by MIPS",
            "#fbbf24", "10, 20, 30, 40, 50, 60"
        ),
        "RAID 5": (
            "RAID 5: 4 disks with rotating distributed parity  |  "
            "multiples of 3 recommended  |  parity rotates per stripe, XOR by MIPS",
            "#c084fc", "10, 20, 30, 40, 50, 60"
        ),
    }

    def _on_level_change(self):
        mode = self.raid.get()
        hint, col, example = self._HINTS[mode]
        self.hint_var.set(hint)
        self.hint_lbl.configure(fg=col)
        self.entry.delete(0, tk.END)
        self.entry.insert(0, example)
        # enable/disable rebuild button
        if mode == "RAID 5":
            self.rebuild_btn.configure(state=tk.NORMAL)
        else:
            self.rebuild_btn.configure(state=tk.DISABLED)
        self._reset()

    # ── RUN ───────────────────────────────────────────────────────────────
    def _run(self):
        raw = self.entry.get().strip()
        if not raw:
            messagebox.showerror("Error", "Enter block values.")
            return
        try:
            vals = [int(x) for x in re.split(r'[\s,]+', raw) if x.strip()]
        except ValueError:
            messagebox.showerror("Error", "Numbers only.\nExample: 10, 20, 30, 40")
            return

        mode = self.raid.get()
        min_vals = {"RAID 0": 2, "RAID 0+1": 2, "RAID 3": 3, "RAID 5": 3}
        if len(vals) < min_vals[mode]:
            messagebox.showerror("Error",
                f"{mode} needs at least {min_vals[mode]} values.")
            return
        if len(vals) > MAX_BLOCKS:
            messagebox.showerror("Error", f"Max {MAX_BLOCKS} values allowed.")
            return

        asm_map = {
            "RAID 0":   "RAID_0.asm",
            "RAID 0+1": "RAID_01.asm",
            "RAID 3":   "RAID_03.asm",
            "RAID 5":   "RAID_05.asm",
        }
        asmfile = asm_map[mode]

        with open(INPUT_FILE, "w") as f:
            f.write(" ".join(map(str, vals)) + "\n")

        self.sv.set(f"Running MIPS ({asmfile})…")
        self.root.update()

        if not self._run_mars(asmfile):
            return

        self.failed  = [False] * 4
        self.rebuilt = [False] * 4
        self._parse_output()
        self.sv.set(f"Done — {len(vals)} values distributed by MIPS  ({mode}).")

        # enable rebuild button only if RAID 5 and there is data
        if mode == "RAID 5":
            self.rebuild_btn.configure(state=tk.NORMAL)

        self._draw()

    # ── REBUILD (RAID 5) ──────────────────────────────────────────────────
    def _rebuild(self):
        """
        Rebuild the failed disk using XOR of the three surviving disks.
        Performed entirely in Python (no MIPS call needed for rebuild).
        MIPS already computed all parity correctly during Write — Python
        just XORs the three surviving disk values slot by slot.
        """
        if not any(self.disks):
            messagebox.showwarning("Warning", "No data loaded yet.")
            return
        if self.raid.get() != "RAID 5":
            messagebox.showwarning("Warning", "Rebuild is only available for RAID 5.")
            return

        failed_indices = [i for i in range(4) if self.failed[i]]
        if len(failed_indices) == 0:
            messagebox.showinfo("No Failure",
                "No disk has been marked as failed.\nUse 'Disk Failure' first.")
            return
        if len(failed_indices) > 1:
            messagebox.showerror("Cannot Rebuild",
                "RAID 5 can only rebuild from a single disk failure.\n"
                f"Currently {len(failed_indices)} disks are marked failed.")
            return

        failed_disk = failed_indices[0]
        self.sv.set(f"Rebuilding Disk {failed_disk} using XOR of surviving disks…")
        self.root.update()

        # ── XOR rebuild in Python ─────────────────────────────────────
        # Find surviving disks
        survivors = [i for i in range(4) if i != failed_disk]

        # Get slot count from first surviving disk
        num_slots = len(self.disks[survivors[0]])

        # Rebuild each slot by XORing all 3 surviving disks
        rebuilt_vals  = []
        rebuilt_flags = []

        for slot in range(num_slots):
            xor_val = 0
            for d in survivors:
                if slot < len(self.disks[d]):
                    xor_val ^= self.disks[d][slot]
            rebuilt_vals.append(xor_val)

            # Determine pflag for rebuilt slot from stripe rotation
            # parity_disk[stripe % 4]: stripe 0->D3, 1->D2, 2->D1, 3->D0
            parity_disk = [3, 2, 1, 0]
            stripe      = slot % 4
            is_parity   = 1 if parity_disk[stripe] == failed_disk else 0
            rebuilt_flags.append(is_parity)

        # Restore failed disk data
        self.disks[failed_disk]  = rebuilt_vals
        self.pflags[failed_disk] = rebuilt_flags

        # Mark as rebuilt
        self.failed[failed_disk]  = False
        self.rebuilt              = [False] * 4
        self.rebuilt[failed_disk] = True

        surviving_str = str([x for x in range(4) if x != failed_disk])
        self.sv.set(
            f"✓  Disk {failed_disk} successfully REBUILT  "
            f"(XOR of Disks {surviving_str})."
        )
        self._draw()

        messagebox.showinfo(
            "Rebuild Complete",
            f"Disk {failed_disk} has been reconstructed!\n\n"
            f"XOR of Disks {surviving_str} slot-by-slot\n"
            f"recovered every block on Disk {failed_disk}.\n\n"
            "The array is now fully operational."
        )

    # ── MARS runner ───────────────────────────────────────────────────────
    def _run_mars(self, asmfile):
        """Run MARS on asmfile. Returns True on success, False on error."""
        cwd      = os.path.dirname(os.path.abspath(__file__))
        out_path = os.path.join(cwd, OUTPUT_FILE)

        # ── Step 1: Rename old output.txt temporarily (don't delete yet) ──
        backup_path = os.path.join(cwd, "output_backup.txt")
        if os.path.exists(out_path):
            os.rename(out_path, backup_path)

        try:
            res = subprocess.run(
                ["java", "-jar", MARS_JAR, asmfile],
                capture_output=True, text=True, timeout=15,
                cwd=cwd
            )
        except FileNotFoundError:
            # Restore backup on failure
            if os.path.exists(backup_path):
                os.rename(backup_path, out_path)
            messagebox.showerror("Error", "Java not found!\nMake sure Java is installed.")
            return False
        except subprocess.TimeoutExpired:
            if os.path.exists(backup_path):
                os.rename(backup_path, out_path)
            messagebox.showerror("Error", "MIPS timed out!")
            return False

        time.sleep(0.3)

        # ── Step 2: Check if new output.txt was created ───────────────────
        if not os.path.exists(out_path):
            # MIPS failed — restore backup and show actual error
            if os.path.exists(backup_path):
                os.rename(backup_path, out_path)

            # Show actual MIPS error to help debug
            err_msg = res.stderr.strip()[:500] if res.stderr.strip() else \
                      res.stdout.strip()[:500] if res.stdout.strip() else \
                      "No error details available."
            messagebox.showerror("MIPS Error",
                f"output.txt not created by MIPS!\n\n"
                f"MIPS output:\n{err_msg}\n\n"
                f"Check {asmfile} is in the same folder as this script.")
            return False

        # ── Step 3: Success — delete backup ───────────────────────────────
        if os.path.exists(backup_path):
            os.remove(backup_path)

        return True

    # ── parse output.txt ──────────────────────────────────────────────────
    def _parse_output(self):
        self.disks  = [[], [], [], []]
        self.pflags = [[], [], [], []]

        cwd      = os.path.dirname(os.path.abspath(__file__))
        out_path = os.path.join(cwd, OUTPUT_FILE)

        with open(out_path, "r") as f:
            for line in f:
                line = line.strip()
                for i, lbl in enumerate(["DISK0:", "DISK1:", "DISK2:", "DISK3:"]):
                    if line.startswith(lbl):
                        self.disks[i] = [
                            int(x)
                            for x in re.split(r'\s+', line[len(lbl):].strip())
                            if x.isdigit()
                        ]
                for i, lbl in enumerate(["PFLAG0:", "PFLAG1:", "PFLAG2:", "PFLAG3:"]):
                    if line.startswith(lbl):
                        self.pflags[i] = [
                            int(x)
                            for x in re.split(r'\s+', line[len(lbl):].strip())
                            if x.isdigit()
                        ]

        # ── FIX 2: If RAID 5 and PFLAG lines missing, compute from stripe rotation ──
        # Stripe rotation pattern (which disk holds parity per stripe):
        #   Stripe 0 -> Parity on D3
        #   Stripe 1 -> Parity on D2
        #   Stripe 2 -> Parity on D1
        #   Stripe 3 -> Parity on D0
        #   (repeats mod 4)
        if self.raid.get() == "RAID 5" and not any(self.pflags):
            # parity_disk[stripe] = which disk holds parity for that stripe
            parity_disk = [3, 2, 1, 0]

            # Figure out how many slots each disk has
            slots = max((len(d) for d in self.disks), default=0)

            # Initialize pflags to all zeros
            for i in range(4):
                self.pflags[i] = [0] * len(self.disks[i])

            # For each stripe (slot index), mark correct disk as parity
            for slot in range(slots):
                stripe = slot % 4
                pdisk  = parity_disk[stripe]
                if slot < len(self.pflags[pdisk]):
                    self.pflags[pdisk][slot] = 1

    # ── DRAW ──────────────────────────────────────────────────────────────
    def _cyl(self, x, y, w, h, tc, bc, rc, label, sublabel=None):
        eh = 16
        self.canvas.create_rectangle(x, y + eh//2, x + w, y + h, fill=bc, outline="")
        self.canvas.create_oval(x, y + h - eh//2, x + w, y + h + eh//2,
                                fill=rc, outline="")
        self.canvas.create_oval(x, y, x + w, y + eh, fill=tc, outline=rc, width=1)
        cy_mid = y + (h + eh) // 2
        if sublabel:
            self.canvas.create_text(x + w//2, cy_mid - 7,
                                    text=label,
                                    font=("Courier New", 10, "bold"), fill="#ffffff")
            self.canvas.create_text(x + w//2, cy_mid + 7,
                                    text=sublabel,
                                    font=("Courier New", 8), fill="#fde68a")
        else:
            self.canvas.create_text(x + w//2, cy_mid,
                                    text=label,
                                    font=("Courier New", 10, "bold"), fill="#ffffff")

    def _draw(self):
        self.canvas.delete("all")
        mode = self.raid.get()

        if mode == "RAID 0":
            info = [("Disk 0", 0, "data"), ("Disk 1", 1, "data")]
        elif mode == "RAID 0+1":
            info = [("Disk 0", 0, "primary"), ("Disk 1", 1, "primary"),
                    ("Disk 2", 2, "mirror"),  ("Disk 3", 3, "mirror")]
        elif mode == "RAID 3":
            info = [("Disk 0", 0, "data"),    ("Disk 1", 1, "data"),
                    ("Disk 2", 2, "data"),    ("Disk 3", 3, "parity3")]
        else:  # RAID 5
            info = [("Disk 0", 0, "raid5"),   ("Disk 1", 1, "raid5"),
                    ("Disk 2", 2, "raid5"),   ("Disk 3", 3, "raid5")]

        nd      = len(info)
        seg_h   = 52
        ell_h   = 16
        start_y = 60
        max_seg = max((len(self.disks[i]) for _, i, _ in info), default=1)
        max_seg = max(max_seg, 1)
        total_h = start_y + max_seg * (seg_h + 4) + ell_h + 80

        cw     = self.canvas.winfo_width() or 1160
        disk_w = min(170, (cw - 40) // nd - 16)
        gap    = (cw - nd * disk_w) // (nd + 1)

        self.canvas.configure(scrollregion=(0, 0, cw, total_h))

        self.canvas.create_text(cw // 2, 24, text=mode,
                                font=("Courier New", 16, "bold"), fill=TITLE)

        for idx, (name, di, role) in enumerate(info):
            fail     = self.failed[di]
            rebuilt  = self.rebuilt[di]
            x        = gap + idx * (disk_w + gap)
            cy       = start_y
            data     = self.disks[di]
            pflags   = self.pflags[di] if self.pflags[di] else [0] * max(len(data), 1)
            slots    = len(data) if data else 1

            for slot in range(slots):
                is_p5 = (role == "raid5") and \
                        (slot < len(pflags)) and \
                        (pflags[slot] == 1)

                if fail:
                    tc, bc, rc = F_TOP, F_BODY, F_RIM
                elif rebuilt:
                    # rebuilt disk: green for data slots, violet for parity
                    if is_p5:
                        tc, bc, rc = PAR5_TOP, PAR5_BODY, PAR5_RIM
                    else:
                        tc, bc, rc = R_TOP, R_BODY, R_RIM
                elif role == "parity3":
                    tc, bc, rc = PAR_TOP, PAR_BODY, PAR_RIM
                elif is_p5:
                    tc, bc, rc = PAR5_TOP, PAR5_BODY, PAR5_RIM
                elif role == "mirror":
                    tc, bc, rc = M_TOP, M_BODY, M_RIM
                else:
                    tc, bc, rc = P_TOP, P_BODY, P_RIM

                if not data:
                    lbl, sub = "—", None
                elif fail:
                    lbl, sub = "FAILED", None
                elif role == "parity3":
                    lbl, sub = str(data[slot]), "XOR parity"
                elif is_p5:
                    lbl, sub = str(data[slot]), "P (XOR)"
                elif rebuilt:
                    lbl, sub = str(data[slot]), "rebuilt ✓"
                else:
                    lbl, sub = str(data[slot]), None

                self._cyl(x, cy, disk_w, seg_h, tc, bc, rc, lbl, sub)
                cy += seg_h + 4

            # bottom cap
            cap_col = F_RIM if fail else \
                      R_RIM if rebuilt else \
                      PAR_RIM if role == "parity3" else \
                      PAR5_RIM if role == "raid5" else P_RIM
            self.canvas.create_oval(x, cy - ell_h//2, x + disk_w, cy + ell_h//2,
                                    fill=cap_col, outline="")

            self.canvas.create_text(x + disk_w//2, cy + ell_h//2 + 14,
                                    text=name,
                                    font=("Courier New", 10, "bold"), fill=FG)

            role_badge = {
                "data":    ("Data",    "#60a5fa"),
                "primary": ("Primary", "#60a5fa"),
                "mirror":  ("Mirror",  "#86efac"),
                "parity3": ("Parity",  "#fbbf24"),
                "raid5":   ("Data+P",  "#c084fc"),
            }
            rlbl, rcol = role_badge.get(role, ("", FG))
            # override badge for rebuilt disk
            if rebuilt:
                rlbl, rcol = "Rebuilt", "#4ade80"
            self.canvas.create_text(x + disk_w//2, cy + ell_h//2 + 28,
                                    text=f"({rlbl})",
                                    font=("Courier New", 9), fill=rcol)

        # legends
        legend_y = total_h - 26
        if mode == "RAID 3":
            self.canvas.create_text(cw // 2, legend_y,
                text="Stripe: D0 | D1 | D2  →  Parity = D0 XOR D1 XOR D2  (MIPS)",
                font=("Courier New", 9, "italic"), fill="#94a3b8")
        elif mode == "RAID 5":
            self.canvas.create_text(cw // 2, legend_y - 10,
                text="Rotating parity (MIPS):  "
                     "Stripe0→P on D3  |  Stripe1→P on D2  |  Stripe2→P on D1  |  Stripe3→P on D0",
                font=("Courier New", 9, "italic"), fill="#94a3b8")
            self.canvas.create_text(cw // 2, legend_y + 8,
                text="Violet = parity  |  Blue = data  |  Green = rebuilt",
                font=("Courier New", 9, "italic"), fill="#c084fc")

    # ── FAIL DIALOG ───────────────────────────────────────────────────────
    def _fail(self):
        if not any(self.disks):
            messagebox.showwarning("Warning", "No data yet!")
            return

        mode = self.raid.get()
        nd   = 2 if mode == "RAID 0" else 4

        dlg = tk.Toplevel(self.root)
        dlg.title("Disk Failure")
        dlg.configure(bg=BG)
        dlg.geometry("400x320")
        dlg.resizable(False, False)

        tk.Label(dlg, text="Select disk to fail:",
                 font=("Courier New", 12, "bold"),
                 bg=BG, fg="#ef4444").pack(pady=10)

        dv = tk.IntVar(value=0)
        for i in range(nd):
            if mode == "RAID 0+1":
                tag = " (Primary)" if i < 2 else " (Mirror)"
            elif mode == "RAID 3":
                tag = " (Parity)" if i == 3 else f" (Data D{i})"
            elif mode == "RAID 5":
                tag = f" (Data+Parity D{i})"
            else:
                tag = ""
            lbl = f"Disk {i}{tag}"
            if self.failed[i]:
                lbl += "  — already failed"
            tk.Radiobutton(dlg, text=lbl, variable=dv, value=i,
                           font=("Courier New", 10), bg=BG, fg=FG,
                           selectcolor="#2d2d44",
                           state=tk.DISABLED if self.failed[i] else tk.NORMAL,
                           activebackground=BG).pack(anchor=tk.W, padx=22, pady=2)

        def confirm():
            d = dv.get()
            if self.failed[d]:
                messagebox.showwarning("Warning", f"Disk {d} already failed!")
                return
            self.failed[d] = True
            self.rebuilt[d] = False
            self._draw()
            dlg.destroy()
            self.sv.set(f"DISK {d} FAILED")

            if mode == "RAID 0":
                messagebox.showerror("Data Lost",
                    f"Disk {d} failed!\nRAID 0 has no redundancy — DATA LOST!")

            elif mode == "RAID 0+1":
                lost = (self.failed[0] and self.failed[2]) or \
                       (self.failed[1] and self.failed[3])
                if lost:
                    messagebox.showerror("Catastrophic", "Both copies lost — DATA LOST!")
                else:
                    messagebox.showinfo("Safe",
                        f"Disk {d} failed.\nMirror intact — data safe.")

            elif mode == "RAID 3":
                n = sum(self.failed[:4])
                if n == 1:
                    if d == 3:
                        messagebox.showinfo("Safe",
                            "Parity disk failed.\nAll data intact on D0/D1/D2.\n"
                            "Replace and rebuild parity.")
                    else:
                        messagebox.showinfo("Recoverable",
                            f"Data Disk {d} failed.\n"
                            "Rebuild via XOR of remaining data disks + parity.")
                else:
                    messagebox.showerror("Data Lost",
                        "Multiple failures — RAID 3 tolerates only 1 — DATA LOST!")

            elif mode == "RAID 5":
                n = sum(self.failed[:4])
                if n == 1:
                    messagebox.showinfo("Recoverable",
                        f"Disk {d} failed.\n"
                        "RAID 5 can reconstruct any single disk\n"
                        "from the remaining 3 disks using XOR parity.\n\n"
                        f"Array is DEGRADED — click 'Rebuild Failed Disk' to restore.")
                else:
                    messagebox.showerror("Data Lost",
                        "Multiple failures — RAID 5 tolerates only 1 — DATA LOST!")

        tk.Button(dlg, text="Confirm Failure",
                  font=("Courier New", 11, "bold"),
                  bg="#ef4444", fg="white", relief=tk.FLAT,
                  padx=10, pady=5, cursor="hand2",
                  command=confirm).pack(pady=14)

    # ── STATUS ────────────────────────────────────────────────────────────
    def _status(self):
        if not any(self.disks):
            messagebox.showwarning("Warning", "No data yet!")
            return

        mode = self.raid.get()
        nd   = 2 if mode == "RAID 0" else 4
        msg  = "── DISK STATUS ──\n\n"

        for i in range(nd):
            if mode == "RAID 0+1":
                role = " (Primary)" if i < 2 else " (Mirror)"
            elif mode == "RAID 3":
                role = " (Parity)" if i == 3 else f" (Data D{i})"
            elif mode == "RAID 5":
                role = f" (Data+Parity D{i})"
            else:
                role = ""
            if self.rebuilt[i]:
                s = "🟢 REBUILT"
            elif self.failed[i]:
                s = "❌ FAILED"
            else:
                s = "✅ HEALTHY"
            msg += f"  Disk {i}{role}:  {s}\n"

        n = sum(self.failed[:nd])
        if mode in ("RAID 3", "RAID 5"):
            msg += f"\n  Failures: {n}/{nd}\n"
            msg += f"  {mode} tolerates exactly 1 disk failure.\n"
            if n == 0 and not any(self.rebuilt[:nd]):
                msg += "  Status: ✅ FULLY OPERATIONAL"
            elif any(self.rebuilt[:nd]):
                msg += "  Status: 🟢 REBUILT — array fully operational"
            elif n == 1:
                msg += "  Status: ⚠️  DEGRADED — rebuild required"
            else:
                msg += "  Status: ❌ ARRAY FAILED — data lost"

        messagebox.showinfo("Disk Status", msg)

    # ── RESET ─────────────────────────────────────────────────────────────
    def _reset(self):
        self.disks   = [[], [], [], []]
        self.pflags  = [[], [], [], []]
        self.failed  = [False] * 4
        self.rebuilt = [False] * 4
        self.canvas.delete("all")
        self.sv.set("Reset — enter new block values.")


if __name__ == "__main__":
    root = tk.Tk()
    RAIDSim(root)
    root.mainloop()